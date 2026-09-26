import Foundation

/// A subtitle line: time span in ms + plain text.
struct TimedLine {
    var startMs: Int
    var endMs: Int
    var text: String
}

/// Subtitles that already exist for a video, to translate instead of recognizing speech: a text subtitle track
/// inside an MKV/WebM (SRT, ASS/SSA, WebVTT), or a subtitle file next to the video (same name, .srt/.ass/.ssa/.vtt).
/// libVLC renders these but offers no way to get their text, so the MKV container is read by the app itself.
enum ExistingSubtitles {
    /// Set to abandon an embedded-track read in progress (the dialog was closed / another option picked).
    static let cancelled = StopFlag()

    struct Option: Identifiable, Hashable {
        enum Kind: Hashable {
            case embedded(track: Int, codec: String, compression: MkvTrack.Compression)
            case sidecar(path: String)
        }
        let id: String
        let label: String
        let kind: Kind
    }

    /// What exists for the video "share/path/name.ext" on `host`.
    static func options(host: String, path: String) async -> [Option] {
        guard let connection = await SmbRegistry.shared.getOrReconnect(host) else { return [] }
        var result: [Option] = []

        // Subtitle tracks inside the file (MKV/WebM: the track list sits in the first megabytes).
        let ext = (path as NSString).pathExtension.lowercased()
        if ["mkv", "webm", "mka"].contains(ext),
           let head = try? await connection.readChunk(path: path, offset: 0, count: 4 * 1024 * 1024) {
            let parser = MkvSubtitleParser(wantedTrack: nil, headerOnly: true)
            parser.feed(head)
            for track in parser.tracks where track.isTextSubtitle {
                let language = track.language.isEmpty || track.language == "und" ? "" : " · \(track.language)"
                let name = track.name.isEmpty ? "Phụ đề \(track.number)" : track.name
                result.append(Option(id: "track\(track.number)", label: "Trong file: \(name)\(language) (\(track.shortCodec))",
                                     kind: .embedded(track: track.number, codec: track.codec, compression: track.compression)))
            }
        }

        // Subtitle files beside it with the same base name ("Movie.srt", "Movie.vi.srt", "Movie.eng.ass"...).
        let folder = (path as NSString).deletingLastPathComponent
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        if let entries = try? await connection.list(path: folder) {
            for entry in entries where !entry.isDirectory {
                let name = entry.name.lowercased()
                guard ["srt", "ass", "ssa", "vtt"].contains((name as NSString).pathExtension), name.hasPrefix(base) else { continue }
                result.append(Option(id: "file:\(entry.path)", label: "File kèm: \(entry.name)", kind: .sidecar(path: entry.path)))
            }
        }
        return result
    }

    /// The lines of `option`. Embedded tracks need the whole file read once (subtitles are spread through it);
    /// `progress` gets 0…1 along the way.
    static func load(_ option: Option, host: String, videoPath: String,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> [TimedLine] {
        guard let connection = await SmbRegistry.shared.getOrReconnect(host) else {
            throw SmbError(message: "Không kết nối được máy chủ.")
        }
        switch option.kind {
        case .sidecar(let path):
            let size = try await connection.fileSize(path: path)
            let data = try await connection.readChunk(path: path, offset: 0, count: Int(min(size, 20_000_000)))
            let text = decode(data)
            let ext = (path as NSString).pathExtension.lowercased()
            let lines = ext == "ass" || ext == "ssa" ? parseAss(text) : parseSrtOrVtt(text)
            guard !lines.isEmpty else { throw SmbError(message: "File phụ đề trống hoặc không đọc được.") }
            return finish(lines)
        case .embedded(let track, _, _):
            let size = max(1, try await connection.fileSize(path: videoPath))
            let parser = MkvSubtitleParser(wantedTrack: track, headerOnly: false)
            let reported = ProgressMark()
            try await connection.streamContents(path: videoPath, from: 0) { chunk in
                if Task.isCancelled || ExistingSubtitles.cancelled.isSet { return false }
                parser.feed(chunk)
                let fraction = Double(parser.consumed) / Double(size)
                if reported.advance(to: fraction) { progress(min(1, fraction)) }
                return !chunk.isEmpty
            }
            let lines = parser.lines
            guard !lines.isEmpty else { throw SmbError(message: "Không tìm thấy dòng phụ đề nào trong track này.") }
            return finish(lines)
        }
    }

    /// Sorted, merged when two lines start together, and given an end when the container had none.
    private static func finish(_ raw: [TimedLine]) -> [TimedLine] {
        var lines = raw.filter { !$0.text.isEmpty }.sorted { $0.startMs < $1.startMs }
        var merged: [TimedLine] = []
        for line in lines {
            if let last = merged.last, last.startMs == line.startMs {
                merged[merged.count - 1].text += "\n" + line.text
                merged[merged.count - 1].endMs = max(last.endMs, line.endMs)
            } else {
                merged.append(line)
            }
        }
        lines = merged
        for i in lines.indices where lines[i].endMs <= lines[i].startMs {
            let next = i + 1 < lines.count ? lines[i + 1].startMs : Int.max
            lines[i].endMs = min(next, lines[i].startMs + max(1500, lines[i].text.count * 60))
        }
        return lines
    }

    // MARK: - Text files

    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            if let text = String(data: data, encoding: .utf16) { return text }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        // Older Vietnamese subtitles are often Windows-1258.
        let cp1258 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsVietnamese.rawValue)))
        if let text = String(data: data, encoding: cp1258) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    static func parseSrtOrVtt(_ text: String) -> [TimedLine] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines: [TimedLine] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let rows = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = rows.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = rows[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2, let start = clock(parts[0]), let end = clock(parts[1]) else { continue }
            let body = rows[(timingIndex + 1)...].joined(separator: "\n")
            lines.append(TimedLine(startMs: start, endMs: end, text: plain(body)))
        }
        return lines
    }

    static func parseAss(_ text: String) -> [TimedLine] {
        var format: [String] = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var lines: [TimedLine] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("format:") {
                format = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            } else if line.lowercased().hasPrefix("dialogue:") {
                let fields = line.dropFirst(9).split(separator: ",", maxSplits: max(0, format.count - 1), omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard let si = format.firstIndex(of: "start"), let ei = format.firstIndex(of: "end"),
                      let ti = format.firstIndex(of: "text"), fields.count > max(si, ei, ti),
                      let start = clock(fields[si]), let end = clock(fields[ei]) else { continue }
                lines.append(TimedLine(startMs: start, endMs: end, text: assPlain(fields[ti])))
            }
        }
        return lines
    }

    /// "01:02:03,456", "01:02:03.45", "1:02:03.45" (ASS centiseconds), "02:03.456" (VTT) → ms.
    static func clock(_ raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
        let pieces = text.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard pieces.count >= 2 else { return nil }
        let secondsPart = pieces.last!.split(separator: ".")
        guard let seconds = Int(secondsPart[0]) else { return nil }
        var fraction = 0
        if secondsPart.count > 1 {
            let digits = String(secondsPart[1].prefix(3))
            fraction = (Int(digits) ?? 0) * (digits.count == 1 ? 100 : digits.count == 2 ? 10 : 1)
        }
        let numbers = pieces.dropLast().compactMap { Int($0) }
        guard numbers.count == pieces.count - 1 else { return nil }
        let minutes = numbers.last ?? 0
        let hours = numbers.count > 1 ? numbers[numbers.count - 2] : 0
        return ((hours * 60 + minutes) * 60 + seconds) * 1000 + fraction
    }

    /// SRT/VTT markup (<i>, <font …>, {\an8}) removed.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ASS override tags removed, \N → new line.
    static func assPlain(_ text: String) -> String {
        plain(text.replacingOccurrences(of: #"\N"#, with: "\n").replacingOccurrences(of: #"\n"#, with: "\n")
                  .replacingOccurrences(of: #"\h"#, with: " "))
    }
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
    func reset() { lock.lock(); value = false; lock.unlock() }
}

/// Reports progress in 1% steps.
private final class ProgressMark: @unchecked Sendable {
    private var last = 0.0
    func advance(to value: Double) -> Bool {
        guard value - last > 0.01 else { return false }
        last = value
        return true
    }
}

/// One track of an MKV, as far as subtitles are concerned.
struct MkvTrack {
    enum Compression: Hashable { case none, zlib, headerStripping(Data) }
    var number = 0
    var type = 0
    var codec = ""
    var language = ""
    var name = ""
    var compression = Compression.none

    var isTextSubtitle: Bool {
        type == 17 && ["S_TEXT/UTF8", "S_TEXT/ASS", "S_TEXT/SSA", "S_TEXT/WEBVTT", "S_TEXT/ASCII"].contains(codec)
    }
    var shortCodec: String { codec.replacingOccurrences(of: "S_TEXT/", with: "") }
}

/// Streaming Matroska reader: fed the file front to back in chunks, it keeps only what it needs — the track list
/// and the blocks of one subtitle track — and skips everything else (video/audio frames) without buffering it.
final class MkvSubtitleParser: @unchecked Sendable {
    private(set) var tracks: [MkvTrack] = []
    private(set) var lines: [TimedLine] = []
    private(set) var consumed: Int64 = 0

    private let wantedTrack: Int?
    private let headerOnly: Bool
    private var done = false

    private var buffer = Data()
    private var bufferStart: Int64 = 0 // file offset of buffer[0]
    private var skip: Int64 = 0

    private struct Open { let id: UInt32; let end: Int64 }
    private var stack: [Open] = []
    private var timecodeScale: Int64 = 1_000_000
    private var clusterTime: Int64 = 0
    private var currentTrack = MkvTrack()
    private var pending: (start: Int64, data: Data)?
    private var pendingDuration: Int64?

    // Element IDs
    private static let segment: UInt32 = 0x18538067, cluster: UInt32 = 0x1F43B675, blockGroup: UInt32 = 0xA0
    private static let info: UInt32 = 0x1549A966, tracksID: UInt32 = 0x1654AE6B, trackEntry: UInt32 = 0xAE
    private static let encodings: UInt32 = 0x6D80, encoding: UInt32 = 0x6240, compressionID: UInt32 = 0x5034
    private static let simpleBlock: UInt32 = 0xA3, block: UInt32 = 0xA1, blockDuration: UInt32 = 0x9B
    private static let timecodeScaleID: UInt32 = 0x2AD7B1, timecode: UInt32 = 0xE7
    private static let trackNumber: UInt32 = 0xD7, trackType: UInt32 = 0x83, codecID: UInt32 = 0x86
    private static let language: UInt32 = 0x22B59C, name: UInt32 = 0x536E
    private static let compAlgo: UInt32 = 0x4254, compSettings: UInt32 = 0x4255
    private static let masters: Set<UInt32> = [segment, cluster, blockGroup, info, tracksID, trackEntry, encodings, encoding, compressionID]
    private static let smallLeaves: Set<UInt32> = [timecodeScaleID, timecode, trackNumber, trackType, codecID, language, name,
                                                   compAlgo, compSettings, blockDuration]
    /// Level-1 children of Segment: seeing one closes an open Cluster of unknown size.
    private static let segmentChildren: Set<UInt32> = [cluster, 0x1C53BB6B, 0x1254C367, 0x1941A469, 0x1043A770, 0x114D9B74, info, tracksID]

    init(wantedTrack: Int?, headerOnly: Bool) {
        self.wantedTrack = wantedTrack
        self.headerOnly = headerOnly
    }

    func feed(_ chunk: Data) {
        guard !done else { return }
        var chunk = chunk
        consumed += Int64(chunk.count)
        if skip > 0 {
            let n = Int(min(skip, Int64(chunk.count)))
            skip -= Int64(n)
            bufferStart += Int64(n)
            chunk = chunk.dropFirst(n)
            if chunk.isEmpty { return }
        }
        buffer.append(chunk)
        parse()
    }

    private var position: Int64 { bufferStart }

    private func consume(_ n: Int) {
        buffer.removeFirst(n)
        bufferStart += Int64(n)
        if buffer.isEmpty { buffer = Data() }
    }

    /// Skips `n` bytes: whatever is buffered now, the rest as it streams in.
    private func skipBytes(_ n: Int64) {
        let now = Int(min(n, Int64(buffer.count)))
        consume(now)
        skip = n - Int64(now)
    }

    private func closeFinished() {
        while let top = stack.last, top.end <= position {
            stack.removeLast()
            closed(top.id)
        }
    }

    private func closed(_ id: UInt32) {
        switch id {
        case Self.trackEntry:
            tracks.append(currentTrack)
            currentTrack = MkvTrack()
        case Self.blockGroup:
            flushPending()
        case Self.tracksID where headerOnly:
            done = true
        default: break
        }
    }

    private func parse() {
        while !done {
            closeFinished()
            if skip > 0 { return }
            guard let (id, idLength) = readID(), let (size, sizeLength) = readSize(at: idLength) else { return }
            let header = idLength + sizeLength
            let unknownSize = size == Int64.max

            if id == Self.cluster || Self.segmentChildren.contains(id), let top = stack.last, top.id == Self.cluster, top.end == Int64.max {
                stack.removeLast() // an unknown-size Cluster ends where the next top-level element starts
                closed(Self.cluster)
            }
            if Self.masters.contains(id) {
                if id == Self.cluster {
                    if headerOnly { done = true; return } // track list is complete by the first Cluster
                    flushPending()
                }
                if id == Self.trackEntry { currentTrack = MkvTrack() }
                consume(header)
                stack.append(Open(id: id, end: unknownSize ? Int64.max : position + size))
                continue
            }
            if Self.smallLeaves.contains(id), size <= 4096 {
                guard buffer.count >= header + Int(size) else { return }
                let payload = buffer.subdata(in: header..<(header + Int(size)))
                consume(header + Int(size))
                leaf(id, payload)
                continue
            }
            if (id == Self.simpleBlock || id == Self.block), !headerOnly, !unknownSize {
                // Track number is the first vint of the block: decide from it whether to keep or skip.
                guard buffer.count >= header + min(Int(size), 8) else { return }
                let track = vint(at: header).map { Int($0.value) } ?? -1
                if track == wantedTrack, size < 2_000_000 {
                    guard buffer.count >= header + Int(size) else { return }
                    let payload = buffer.subdata(in: header..<(header + Int(size)))
                    consume(header + Int(size))
                    block(payload, simple: id == Self.simpleBlock)
                } else {
                    consume(header)
                    skipBytes(size)
                }
                continue
            }
            // Anything else: skip it without buffering.
            consume(header)
            if unknownSize { continue }
            skipBytes(size)
        }
    }

    private func leaf(_ id: UInt32, _ payload: Data) {
        switch id {
        case Self.timecodeScaleID: timecodeScale = max(1, Int64(uint(payload)))
        case Self.timecode: clusterTime = Int64(uint(payload))
        case Self.trackNumber: currentTrack.number = Int(uint(payload))
        case Self.trackType: currentTrack.type = Int(uint(payload))
        case Self.codecID: currentTrack.codec = string(payload)
        case Self.language: currentTrack.language = string(payload)
        case Self.name: currentTrack.name = string(payload)
        case Self.compAlgo:
            switch uint(payload) {
            case 0: currentTrack.compression = .zlib
            case 3: if case .headerStripping = currentTrack.compression {} else { currentTrack.compression = .headerStripping(Data()) }
            default: break
            }
        case Self.compSettings:
            currentTrack.compression = .headerStripping(payload)
        case Self.blockDuration:
            pendingDuration = Int64(uint(payload))
        default: break
        }
    }

    /// A block of the wanted track: [track vint][int16 relative time][flags][data].
    private func block(_ payload: Data, simple: Bool) {
        guard let track = vint(at: 0, in: payload) else { return }
        let offset = track.length
        guard payload.count >= offset + 3 else { return }
        let bytes = [UInt8](payload[payload.startIndex + offset..<payload.startIndex + offset + 2])
        let relative = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        let flags = payload[payload.startIndex + offset + 2]
        guard flags & 0x06 == 0 else { return } // laced: never used for text subtitles
        let data = payload.subdata(in: (payload.startIndex + offset + 3)..<payload.endIndex)
        flushPending()
        pending = (clusterTime + Int64(relative), data)
        pendingDuration = nil
        if simple { flushPending() }
    }

    private func flushPending() {
        guard let pending else { return }
        self.pending = nil
        let startMs = Int(pending.start * timecodeScale / 1_000_000)
        let endMs = pendingDuration.map { startMs + Int($0 * timecodeScale / 1_000_000) } ?? 0
        pendingDuration = nil
        let track = tracks.first { $0.number == wantedTrack }
        var data = pending.data
        switch track?.compression ?? .none {
        case .zlib:
            if data.count > 2, let inflated = try? (data.dropFirst(2) as NSData).decompressed(using: .zlib) as Data { data = inflated }
        case .headerStripping(let prefix):
            data = prefix + data
        case .none: break
        }
        var text = String(decoding: data, as: UTF8.self)
        if let codec = track?.codec, codec == "S_TEXT/ASS" || codec == "S_TEXT/SSA" {
            // ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
            let fields = text.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            text = ExistingSubtitles.assPlain(fields.count == 9 ? String(fields[8]) : text)
        } else {
            text = ExistingSubtitles.plain(text)
        }
        lines.append(TimedLine(startMs: startMs, endMs: endMs, text: text))
    }

    // MARK: - EBML primitives

    private func readID() -> (UInt32, Int)? {
        // Not an element start (corrupt data): move on byte by byte until one is.
        while let first = buffer.first, first < 0x10 { consume(1) }
        guard let first = buffer.first else { return nil }
        let length = first >= 0x80 ? 1 : first >= 0x40 ? 2 : first >= 0x20 ? 3 : 4
        guard buffer.count >= length else { return nil }
        var id: UInt32 = 0
        for i in 0..<length { id = id << 8 | UInt32(buffer[buffer.startIndex + i]) }
        return (id, length)
    }

    private func readSize(at offset: Int) -> (Int64, Int)? {
        guard let v = vint(at: offset) else { return nil }
        let allOnes = (UInt64(1) << (7 * UInt64(v.length))) - 1
        return (v.value == allOnes ? Int64.max : Int64(v.value), v.length)
    }

    private func vint(at offset: Int, in data: Data? = nil) -> (value: UInt64, length: Int)? {
        let source = data ?? buffer
        guard source.count > offset else { return nil }
        let first = source[source.startIndex + offset]
        var length = 1
        var mask: UInt8 = 0x80
        while length <= 8, first & mask == 0 { length += 1; mask >>= 1 }
        guard length <= 8, source.count >= offset + length else { return nil }
        var value = UInt64(first & (mask &- 1))
        for i in 1..<length { value = value << 8 | UInt64(source[source.startIndex + offset + i]) }
        return (value, length)
    }

    private func uint(_ data: Data) -> UInt64 {
        data.reduce(0) { $0 << 8 | UInt64($1) }
    }

    private func string(_ data: Data) -> String {
        String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
    }
}
