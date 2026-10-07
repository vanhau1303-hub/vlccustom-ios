import Foundation

/// A video's duration read straight from its header with a few small SMB reads — MKV/WebM (Segment Info), MP4/MOV
/// (mvhd, wherever the moov box sits) and AVI (avih). Lets a thumbnail open libVLC once, right at 25%, instead of
/// first opening the file just to learn its length (that first open was half the time of every thumbnail).
/// Nil for other formats or an unusual header: the caller then falls back to asking libVLC.
enum MediaHeaderDuration {
    private static let cache = NSCache<NSString, NSNumber>()

    static func lengthMs(host: String, path: String) async -> Int64? {
        let key = "\(host)/\(path)" as NSString
        if let known = cache.object(forKey: key) { return known.int64Value }
        guard let connection = await SmbRegistry.shared.getOrReconnect(host) else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        let read: (Int64, Int) async -> Data? = { offset, count in
            try? await connection.readChunk(path: path, offset: offset, count: count)
        }
        let ms: Int64?
        switch ext {
        case "mkv", "webm", "mka", "mk3d": ms = await matroska(read)
        case "mp4", "m4v", "mov", "3gp", "3g2", "m4a": ms = await mp4(read)
        case "avi": ms = await avi(read)
        default: ms = nil
        }
        guard let ms, ms > 0 else { return nil }
        cache.setObject(NSNumber(value: ms), forKey: key)
        return ms
    }

    // MARK: - Matroska

    private static func matroska(_ read: (Int64, Int) async -> Data?) async -> Int64? {
        guard let data = await read(0, 256 * 1024) else { return nil }
        let bytes = [UInt8](data)
        var pos = 0
        // EBML header, then the Segment.
        guard let header = element(bytes, &pos), header.id == 0x1A45DFA3 else { return nil }
        pos = header.dataStart + header.size
        guard let segment = element(bytes, &pos), segment.id == 0x18538067 else { return nil }
        pos = segment.dataStart
        while pos < bytes.count {
            guard let child = element(bytes, &pos) else { return nil }
            if child.id == 0x1F43B675 { return nil } // first Cluster reached without an Info
            if child.id == 0x1549A966 { // Info
                var scale: Double = 1_000_000
                var duration: Double?
                var inner = child.dataStart
                let end = min(bytes.count, child.dataStart + child.size)
                while inner < end, let e = element(bytes, &inner) {
                    let payload = Array(bytes[e.dataStart..<min(bytes.count, e.dataStart + e.size)])
                    if e.id == 0x2AD7B1 { scale = Double(uint(payload)) }
                    if e.id == 0x4489 { duration = float(payload) }
                    inner = e.dataStart + e.size
                }
                guard let duration, duration > 0 else { return nil }
                return Int64(duration * scale / 1_000_000)
            }
            pos = child.dataStart + child.size
        }
        return nil
    }

    private struct Element { let id: UInt32; let size: Int; let dataStart: Int }

    private static func element(_ b: [UInt8], _ pos: inout Int) -> Element? {
        guard pos < b.count else { return nil }
        // ID: 1-4 bytes, length marker kept.
        let first = b[pos]
        var idLength = 1
        while idLength <= 4, first & (0x80 >> (idLength - 1)) == 0 { idLength += 1 }
        guard idLength <= 4, pos + idLength <= b.count else { return nil }
        var id: UInt32 = 0
        for i in 0..<idLength { id = id << 8 | UInt32(b[pos + i]) }
        pos += idLength
        // Size: 1-8 bytes, marker removed; all ones = unknown size.
        guard pos < b.count else { return nil }
        let s0 = b[pos]
        var sizeLength = 1
        while sizeLength <= 8, s0 & (0x80 >> (sizeLength - 1)) == 0 { sizeLength += 1 }
        guard sizeLength <= 8, pos + sizeLength <= b.count else { return nil }
        var size = UInt64(s0 & (0xFF >> sizeLength))
        var allOnes = size == UInt64(0xFF >> sizeLength)
        for i in 1..<sizeLength {
            size = size << 8 | UInt64(b[pos + i])
            if b[pos + i] != 0xFF { allOnes = false }
        }
        pos += sizeLength
        let clamped = allOnes || size > UInt64(Int.max / 2) ? Int.max / 2 : Int(size)
        return Element(id: id, size: clamped, dataStart: pos)
    }

    private static func uint(_ p: [UInt8]) -> UInt64 { p.reduce(0) { $0 << 8 | UInt64($1) } }

    private static func float(_ p: [UInt8]) -> Double? {
        switch p.count {
        case 4: return Double(Float(bitPattern: UInt32(uint(p))))
        case 8: return Double(bitPattern: uint(p))
        default: return nil
        }
    }

    // MARK: - MP4 / MOV

    private static func mp4(_ read: (Int64, Int) async -> Data?) async -> Int64? {
        var offset: Int64 = 0
        for _ in 0..<32 { // top-level boxes: ftyp, mdat, moov, free...
            guard let head = await read(offset, 16), head.count >= 8 else { return nil }
            let h = [UInt8](head)
            var size = Int64(uint(Array(h[0..<4])))
            let type = String(bytes: h[4..<8], encoding: .ascii) ?? ""
            var headerLength: Int64 = 8
            if size == 1, h.count >= 16 { size = Int64(uint(Array(h[8..<16]))); headerLength = 16 }
            if type == "moov" {
                guard let moov = await read(offset + headerLength, 64 * 1024) else { return nil }
                return mvhd(in: [UInt8](moov))
            }
            guard size >= headerLength else { return nil } // size 0 = to the end of the file: no moov after it
            offset += size
        }
        return nil
    }

    private static func mvhd(in b: [UInt8]) -> Int64? {
        var pos = 0
        while pos + 8 <= b.count {
            let size = Int(uint(Array(b[pos..<pos + 4])))
            let type = String(bytes: b[pos + 4..<pos + 8], encoding: .ascii) ?? ""
            if type == "mvhd" {
                let p = pos + 8
                guard p + 32 <= b.count else { return nil }
                let version = b[p]
                let timescale: UInt64
                let duration: UInt64
                if version == 1 {
                    timescale = uint(Array(b[p + 20..<p + 24]))
                    duration = uint(Array(b[p + 24..<p + 32]))
                } else {
                    timescale = uint(Array(b[p + 12..<p + 16]))
                    duration = uint(Array(b[p + 16..<p + 20]))
                }
                guard timescale > 0, duration > 0, duration != 0xFFFF_FFFF else { return nil }
                return Int64(Double(duration) / Double(timescale) * 1000)
            }
            guard size >= 8 else { return nil }
            pos += size
        }
        return nil
    }

    // MARK: - AVI

    private static func avi(_ read: (Int64, Int) async -> Data?) async -> Int64? {
        guard let data = await read(0, 4096) else { return nil }
        let b = [UInt8](data)
        guard b.count > 64, String(bytes: b[0..<4], encoding: .ascii) == "RIFF",
              let range = b.rangeOfBytes(Array("avih".utf8)) else { return nil }
        let p = range.lowerBound + 8 // "avih" + chunk size
        guard p + 20 <= b.count else { return nil }
        func le(_ i: Int) -> UInt64 { UInt64(b[i]) | UInt64(b[i + 1]) << 8 | UInt64(b[i + 2]) << 16 | UInt64(b[i + 3]) << 24 }
        let microsPerFrame = le(p)
        let frames = le(p + 16)
        guard microsPerFrame > 0, frames > 0 else { return nil }
        return Int64(microsPerFrame * frames / 1000)
    }
}

private extension Array where Element == UInt8 {
    func rangeOfBytes(_ pattern: [UInt8]) -> Range<Int>? {
        guard pattern.count <= count else { return nil }
        for i in 0...(count - pattern.count) where Array(self[i..<i + pattern.count]) == pattern {
            return i..<i + pattern.count
        }
        return nil
    }
}
