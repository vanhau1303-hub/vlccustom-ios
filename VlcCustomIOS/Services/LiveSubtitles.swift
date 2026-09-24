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

    func serialized() -> String {
        spans.map { "\($0.0)-\($0.1)" }.joined(separator: ",")
    }
}

/// Generates subtitles from a video's own audio track on-device (WhisperKit/Core ML), optionally translated, and
/// exposes the growing cue list for the player to overlay. A scoped equivalent of the Android app's `LiveSubtitles`:
/// same windowed-recognition-with-resumable-coverage design, simplified to a single engine (WhisperKit; there is no
/// iOS build of Moonshine) and a single always-forward-from-the-first-gap scan (no lookahead-idle/seek-biasing).
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

        var cursor = coverage.firstGap(limit: durationMs)
        while running, !Task.isCancelled, cursor < durationMs {
            status = "Đang nhận dạng giọng nói… (\(cursor / 1000)s / \(durationMs / 1000)s)"
            let length = min(Self.windowMs, durationMs - cursor)
            do {
                // SMB: libVLC transcodes the window itself (any format, over its own SMB2 module). Local files keep
                // AVAssetReader, which reads them directly.
                let samples: [Float]
                if let smb {
                    samples = try await VlcAudioExtractor.extract(host: smb.host, path: smb.path, login: login,
                                                                  startMs: cursor, durationMs: length)
                } else {
                    samples = try await AudioPcmExtractor.extract(url: localURL!, startMs: cursor, durationMs: length)
                }
                guard !samples.isEmpty else {
                    coverage.mark(cursor, cursor + length)
                    persist()
                    cursor += length
                    continue
                }
                if rms(samples) < Self.silenceRms {
                    coverage.mark(cursor, cursor + length)
                    persist()
                    cursor += length
                    continue
                }

                // skipSpecialTokens: without it every segment's text carried Whisper's control tokens
                // ("<|startoftranscript|><|vi|><|0.00|>…") — the "code" that showed up instead of subtitles.
                let options = DecodingOptions(task: .transcribe, language: language, skipSpecialTokens: true, noSpeechThreshold: 0.6)
                let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)

                var advanced = length
                if let segments = results.first?.segments, !segments.isEmpty {
                    var lastEndMs = 0
                    for segment in segments {
                        let text = cleanText(segment.text)
                        guard !text.isEmpty else { continue }
                        let startMs = cursor + Int(segment.start * 1000)
                        let recognizedEndMs = cursor + Int(segment.end * 1000)
                        let endMs = SubtitleLayout.endFor(startMs: startMs, recognizedEndMs: recognizedEndMs, text: text)

                        // Shown in the original language right away; translated in place when the translation
                        // comes back — or later, if the translation service is out of quota for now.
                        cues.append(LiveCue(startMs: startMs, endMs: endMs, text: SubtitleLayout.wrap(text)))
                        if self.translateTo != nil {
                            pending[startMs] = text
                            await translatePendingNow(limit: 1, only: startMs)
                        }
                        lastEndMs = max(lastEndMs, Int(segment.end * 1000))
                    }
                    cues.sort { $0.startMs < $1.startMs }
                    if lastEndMs > 0 { advanced = lastEndMs }
                }
                coverage.mark(cursor, cursor + advanced)
                persist()
                cursor += advanced
            } catch {
                errorMessage = "Lỗi nhận dạng: \(error.localizedDescription)"
                break
            }
        }
        status = nil
        running = false
        startDrainingIfNeeded()
    }

    // MARK: - Translation queue

    /// Tries to translate queued cues (all, or just `only`) unless the service asked us to wait.
    private func translatePendingNow(limit: Int = .max, only: Int? = nil) async {
        guard let translateTo else { return }
        if let pausedUntil, pausedUntil > Date() { updateTranslationNote(); return }
        let keys = only.map { [$0] } ?? pending.keys.sorted()
        var done = 0
        for start in keys {
            guard done < limit, !Task.isCancelled, let original = pending[start] else { continue }
            do {
                let translated = try await SubtitleTranslator.translate(
                    original, from: sourceLanguage ?? "auto", to: translateTo,
                    serverURL: SpeechSettings.shared.libreTranslateServer)
                apply(translated, original: original, to: start)
                pending[start] = nil
                backoffSeconds = 60
                done += 1
            } catch {
                // Out of quota or offline: keep the line queued and come back later, backing off up to 15 minutes.
                let rateLimited = (error as? SubtitleTranslator.TranslateError)?.isRateLimited ?? false
                PlaybackDiagnostics.append("translate: \(error.localizedDescription) — retry in \(Int(backoffSeconds))s")
                pausedUntil = Date().addingTimeInterval(backoffSeconds)
                backoffSeconds = min(rateLimited ? backoffSeconds * 2 : backoffSeconds * 1.5, 900)
                break
            }
        }
        savePending()
        persist()
        updateTranslationNote()
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
                let wait = max(2, self.pausedUntil.map { $0.timeIntervalSinceNow } ?? 2)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                if Task.isCancelled { break }
                await self.translatePendingNow(limit: 20)
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
