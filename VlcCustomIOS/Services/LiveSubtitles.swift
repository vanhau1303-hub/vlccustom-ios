import Foundation
import CryptoKit
import WhisperKit

/// Merged, sorted spans of a video's timeline that have already been transcribed, persisted to a sidecar file so
/// re-opening the same video (with the same settings) resumes instead of starting over.
private struct Coverage {
    private(set) var spans: [(Int, Int)] = []

    init() {}

    init(loading url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return }
        spans = text.split(separator: ",").compactMap { part -> (Int, Int)? in
            let numbers = part.split(separator: "-").compactMap { Int($0) }
            guard numbers.count == 2 else { return nil }
            return (numbers[0], numbers[1])
        }
    }

    mutating func mark(_ start: Int, _ end: Int) {
        guard end > start else { return }
        spans.append((start, end))
        spans.sort { $0.0 < $1.0 }
        var merged: [(Int, Int)] = []
        for span in spans {
            if let last = merged.last, span.0 <= last.1 {
                merged[merged.count - 1] = (last.0, max(last.1, span.1))
            } else {
                merged.append(span)
            }
        }
        spans = merged
    }

    /// The earliest millisecond not yet covered — always resume from the first gap, so a partially generated
    /// transcript picks up where it left off regardless of where playback currently is.
    func firstGap(limit: Int) -> Int {
        var cursor = 0
        for span in spans {
            if span.0 > cursor { return min(cursor, limit) }
            cursor = max(cursor, span.1)
        }
        return min(cursor, limit)
    }

    /// The first uncovered millisecond at or after `from` (nil if everything from there to `limit` is done).
    func nextGap(from: Int, limit: Int) -> Int? {
        var cursor = max(0, from)
        for span in spans where span.1 > cursor {
            if span.0 > cursor { break }
            cursor = span.1
        }
        return cursor < limit ? cursor : nil
    }

    func serialized() -> String {
        spans.map { "\($0.0)-\($0.1)" }.joined(separator: ",")
    }
}

/// Generates subtitles from a video's own audio track on-device (WhisperKit/Core ML), optionally translated, and
/// exposes the growing cue list for the player to overlay. A scoped equivalent of the Android app's `LiveSubtitles`:
/// same windowed-recognition-with-resumable-coverage design, simplified to a single engine (WhisperKit; there is no
/// iOS build of Moonshine). Work follows the playhead (a seek moves recognition there on the next window), the next
/// window's audio is extracted while the current one is recognized, and translation runs in batches in the background.
@MainActor
final class LiveSubtitles: ObservableObject {
    static let shared = LiveSubtitles()

    @Published var status: String?
    @Published var errorMessage: String?
    @Published var running = false
    @Published private(set) var cues: [LiveCue] = []
    /// Lines recognized but not translated yet (translation service out of quota / offline), e.g.
    /// "Còn 12 câu chưa dịch — tự dịch tiếp lúc 14:05". Nil when nothing is waiting.
    @Published private(set) var translationNote: String?

    /// Where the video currently is — set by the player, so recognition follows seeks instead of plodding on from
    /// the start of the file.
    var playheadProvider: (() -> Int)?

    private static let windowMs = 30_000
    private static let silenceRms: Float = 150.0 / 32768.0

    private var task: Task<Void, Never>?
    private var coverage = Coverage()
    private var subtitleURL: URL?
    private var coverageURL: URL?

    // Translation queue: original text of cues still waiting for a translation, keyed by cue start. Persisted next
    // to the .srt so reopening the video later keeps translating where it stopped (e.g. once the quota reset).
    private var pending: [Int: String] = [:]
    private var pendingURL: URL?
    private var translateTo: String?
    private var sourceLanguage: String?
    private var dual = false
    private var pausedUntil: Date?
    private var backoffSeconds: Double = 60
    private var drainTask: Task<Void, Never>?

    func start(source: String, durationMs: Int, modelSize: String, language: String?, translateTo: String?, dual: Bool) {
        stop()
        errorMessage = nil

        let key = Self.cacheKey(source: source, language: language, translateTo: translateTo, dual: dual)
        let dir = Self.subsDirectory()
        let subtitleURL = dir.appendingPathComponent("asr_\(key).srt")
        let coverageURL = dir.appendingPathComponent("asr_\(key).cov")
        self.subtitleURL = subtitleURL
        self.coverageURL = coverageURL
        cues = Srt.read(subtitleURL)
        coverage = Coverage(loading: coverageURL)
        self.translateTo = (translateTo?.isEmpty ?? true) ? nil : translateTo
        self.sourceLanguage = language
        self.dual = dual
        let pendingURL = dir.appendingPathComponent("asr_\(key).pending.json")
        self.pendingURL = pendingURL
        pending = Self.loadPending(pendingURL)
        pausedUntil = nil
        backoffSeconds = 60
        updateTranslationNote()
        startDrainingIfNeeded()

        running = true
        task = Task { [weak self] in
            await self?.run(source: source, durationMs: durationMs, modelSize: modelSize, language: language, translateTo: translateTo, dual: dual)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        drainTask?.cancel()
        drainTask = nil
        translationNote = nil
        running = false
        status = nil
    }

    /// The cue that should be on screen at `ms` (with a little slack either side, like the Android overlay).
    func activeCue(at ms: Int) -> LiveCue? {
        cues.last { ms >= $0.startMs - 150 && ms <= $0.endMs + 150 }
    }

    private func run(source: String, durationMs: Int, modelSize: String, language: String?, translateTo: String?, dual: Bool) async {
        let smb = SmbUri.parse(source)
        let localURL = smb == nil ? URL(string: source) : nil
        if smb == nil && localURL == nil {
            errorMessage = "Không mở được file để nhận dạng."
            running = false
            return
        }
        var login: SmbPlayback.Login?
        if let smb { login = await SmbRegistry.shared.login(for: smb.host) }
        guard durationMs > 0 else {
            errorMessage = "Chưa biết thời lượng video."
            running = false
            return
        }

        status = "Đang tải mô hình nhận dạng giọng nói (chỉ lần đầu)…"
        let whisper: WhisperKit
        do {
            whisper = try await WhisperEngine.shared.instance(model: modelSize)
        } catch {
            errorMessage = "Không tải được mô hình: \(error.localizedDescription)"
            status = nil
            running = false
            return
        }

        // Audio for one window, extracted ahead of time while the previous window is being recognized.
        func extract(_ startMs: Int, _ length: Int) -> Task<[Float], Error> {
            Task { @MainActor in
                if let smb {
                    return try await VlcAudioExtractor.extract(host: smb.host, path: smb.path, login: login,
                                                               startMs: startMs, durationMs: length)
                }
                return try await AudioPcmExtractor.extract(url: localURL!, startMs: startMs, durationMs: length)
            }
        }
        var prefetched: (start: Int, length: Int, task: Task<[Float], Error>)?

        while running, !Task.isCancelled {
            // Always work where the viewer is: the first gap at (slightly before) the playhead — a seek moves the
            // work there on the very next window. Only once everything ahead is done are earlier gaps filled in.
            let playhead = playheadProvider?() ?? 0
            guard let cursor = coverage.nextGap(from: max(0, playhead - 2_000), limit: durationMs)
                ?? coverage.nextGap(from: 0, limit: durationMs) else { break }
            let length = min(Self.windowMs, durationMs - cursor)
            status = "Đang nhận dạng giọng nói… (\(Self.clock(cursor)) / \(Self.clock(durationMs)))"

            let audio: Task<[Float], Error>
            if let prefetched, prefetched.start == cursor, prefetched.length == length {
                audio = prefetched.task
            } else {
                prefetched?.task.cancel()
                audio = extract(cursor, length)
            }
            prefetched = nil

            do {
                let samples = try await audio.value

                // Start pulling the next window's audio now, so it is ready when recognition of this one ends.
                let nextStart = cursor + length
                if nextStart < durationMs, coverage.nextGap(from: nextStart, limit: durationMs) == nextStart {
                    let nextLength = min(Self.windowMs, durationMs - nextStart)
                    prefetched = (nextStart, nextLength, extract(nextStart, nextLength))
                }

                if samples.isEmpty || rms(samples) < Self.silenceRms {
                    coverage.mark(cursor, cursor + length)
                    persist()
                    continue
                }

                // skipSpecialTokens: without it every segment's text carried Whisper's control tokens
                // ("<|startoftranscript|><|vi|><|0.00|>…") — the "code" that showed up instead of subtitles.
                // temperatureFallbackCount 2 (default 5): hard-to-hear windows no longer get decoded 6 times over.
                let options = DecodingOptions(task: .transcribe, language: language, temperatureFallbackCount: 2,
                                              skipSpecialTokens: true, noSpeechThreshold: 0.6)
                let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)

                if let segments = results.first?.segments, !segments.isEmpty {
                    for segment in segments {
                        let text = cleanText(segment.text)
                        guard !text.isEmpty else { continue }
                        let startMs = cursor + Int(segment.start * 1000)
                        let recognizedEndMs = cursor + Int(segment.end * 1000)
                        let endMs = SubtitleLayout.endFor(startMs: startMs, recognizedEndMs: recognizedEndMs, text: text)
                        // Shown in the original language right away; translated in place by the background
                        // translation queue (batched), without holding up recognition of the next window.
                        cues.removeAll { $0.startMs == startMs }
                        cues.append(LiveCue(startMs: startMs, endMs: endMs, text: SubtitleLayout.wrap(text)))
                        if self.translateTo != nil { pending[startMs] = text }
                    }
                    cues.sort { $0.startMs < $1.startMs }
                }
                // Whole windows, back to back: the next window's audio is already being extracted from exactly
                // cursor + length, so it can be used as is.
                coverage.mark(cursor, cursor + length)
                persist()
                if self.translateTo != nil {
                    savePending()
                    startDrainingIfNeeded()
                }
            } catch {
                if Task.isCancelled { break }
                errorMessage = "Lỗi nhận dạng: \(error.localizedDescription)"
                break
            }
        }
        prefetched?.task.cancel()
        status = nil
        running = false
        startDrainingIfNeeded()
    }

    // MARK: - Translation queue

    /// Translates queued lines in batches (one request for up to `batchSize` lines, instead of one per line),
    /// nearest to the playhead first, unless the service asked us to wait.
    private func translatePendingNow(batchSize: Int = 12) async {
        guard let translateTo, !pending.isEmpty else { return }
        if let pausedUntil, pausedUntil > Date() { updateTranslationNote(); return }
        let playhead = playheadProvider?() ?? 0
        // Ahead of the playhead first (closest first), then whatever lies behind it.
        let keys = pending.keys.sorted { a, b in
            let aAhead = a >= playhead - 5_000, bAhead = b >= playhead - 5_000
            if aAhead != bAhead { return aAhead }
            return abs(a - playhead) < abs(b - playhead)
        }
        let batch = Array(keys.prefix(batchSize)).sorted()
        let originals = batch.compactMap { pending[$0] }
        guard originals.count == batch.count else { return }
        do {
            let translations = try await translateBatch(originals, to: translateTo)
            for (start, (original, translated)) in zip(batch, zip(originals, translations)) {
                apply(translated, original: original, to: start)
                pending[start] = nil
            }
            backoffSeconds = 60
        } catch {
            // Out of quota or offline: keep the lines queued and come back later, backing off up to 15 minutes.
            let rateLimited = (error as? SubtitleTranslator.TranslateError)?.isRateLimited ?? false
            PlaybackDiagnostics.append("translate: \(error.localizedDescription) — retry in \(Int(backoffSeconds))s")
            pausedUntil = Date().addingTimeInterval(backoffSeconds)
            backoffSeconds = min(rateLimited ? backoffSeconds * 2 : backoffSeconds * 1.5, 900)
        }
        savePending()
        persist()
        updateTranslationNote()
    }

    /// One request for several lines, joined by newlines; falls back to one request per line if the service does
    /// not give back the same number of lines.
    private func translateBatch(_ lines: [String], to target: String) async throws -> [String] {
        let server = SpeechSettings.shared.libreTranslateServer
        let from = sourceLanguage ?? "auto"
        if lines.count > 1 {
            let clean = lines.map { $0.replacingOccurrences(of: "\n", with: " ") }
            let joined = try await SubtitleTranslator.translate(clean.joined(separator: "\n"), from: from, to: target, serverURL: server)
            let parts = joined.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if parts.count == lines.count { return parts }
        }
        var result: [String] = []
        for line in lines {
            result.append(try await SubtitleTranslator.translate(line, from: from, to: target, serverURL: server))
        }
        return result
    }

    private func apply(_ translated: String, original: String, to start: Int) {
        guard let index = cues.firstIndex(where: { $0.startMs == start }) else { return }
        let cue = cues[index]
        let wrappedTranslation = SubtitleLayout.wrap(translated)
        let text = dual ? SubtitleLayout.wrap(original) + "\n" + wrappedTranslation : wrappedTranslation
        cues[index] = LiveCue(startMs: cue.startMs, endMs: cue.endMs, text: text)
    }

    /// Keeps retrying the queue in the background — even after recognition finished — until it is empty.
    private func startDrainingIfNeeded() {
        guard drainTask == nil, translateTo != nil, !pending.isEmpty else { return }
        drainTask = Task { [weak self] in
            while let self, !Task.isCancelled, !self.pending.isEmpty {
                let wait = max(0.2, self.pausedUntil.map { $0.timeIntervalSinceNow } ?? 0.2)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                if Task.isCancelled { break }
                await self.translatePendingNow()
            }
            self?.drainTask = nil
        }
    }

    private func updateTranslationNote() {
        guard translateTo != nil, !pending.isEmpty else { translationNote = nil; return }
        if let pausedUntil, pausedUntil > Date() {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            translationNote = "Còn \(pending.count) câu chưa dịch (dịch vụ tạm hết lượt) — tự dịch tiếp lúc \(formatter.string(from: pausedUntil))"
        } else {
            translationNote = "Đang dịch… còn \(pending.count) câu"
        }
    }

    private func savePending() {
        guard let pendingURL else { return }
        if pending.isEmpty {
            try? FileManager.default.removeItem(at: pendingURL)
            return
        }
        let dict = Dictionary(uniqueKeysWithValues: pending.map { (String($0.key), $0.value) })
        if let data = try? JSONSerialization.data(withJSONObject: dict) { try? data.write(to: pendingURL) }
    }

    private static func loadPending(_ url: URL) -> [Int: String] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        var result: [Int: String] = [:]
        for (key, value) in dict { if let start = Int(key) { result[start] = value } }
        return result
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }

    private func persist() {
        guard let subtitleURL, let coverageURL else { return }
        Srt.write(cues, to: subtitleURL)
        try? coverage.serialized().write(to: coverageURL, atomically: true, encoding: .utf8)
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sumSquares / Float(samples.count)).squareRoot()
    }

    private func cleanText(_ raw: String) -> String {
        // Belt and braces on top of skipSpecialTokens: strip any "<|...|>" control token left in the text.
        let stripped = raw.replacingOccurrences(of: #"<\|[^|>]*\|>"#, with: "", options: .regularExpression)
        let text = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }
        if text.hasPrefix("[") && text.hasSuffix("]") { return "" }
        if text.hasPrefix("(") && text.hasSuffix(")") { return "" }
        if text.hasPrefix("♪") { return "" }
        return text
    }

    private static func subsDirectory() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("subs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheKey(source: String, language: String?, translateTo: String?, dual: Bool) -> String {
        let raw = "v2|\(source)|\(language ?? "auto")|\(translateTo ?? "")|\(dual)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
