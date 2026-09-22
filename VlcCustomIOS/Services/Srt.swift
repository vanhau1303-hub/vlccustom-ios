import Foundation

/// Minimal SubRip (.srt) reader/writer for AI-generated cues.
enum Srt {
    static func read(_ url: URL) -> [LiveCue] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var cues: [LiveCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard lines.count >= 3 else { continue }
            let timeParts = lines[1].components(separatedBy: " --> ")
            guard timeParts.count == 2, let start = parseTime(timeParts[0]), let end = parseTime(timeParts[1]) else { continue }
            let text = lines[2...].joined(separator: "\n")
            guard !text.isEmpty else { continue }
            cues.append(LiveCue(startMs: start, endMs: end, text: text))
        }
        return cues.sorted { $0.startMs < $1.startMs }
    }

    static func write(_ cues: [LiveCue], to url: URL) {
        var out = ""
        for (index, cue) in cues.enumerated() {
            out += "\(index + 1)\n\(timeString(cue.startMs)) --> \(timeString(cue.endMs))\n\(cue.text)\n\n"
        }
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }

    static func timeString(_ ms: Int) -> String {
        let clamped = max(0, ms)
        let h = clamped / 3_600_000
        let m = (clamped % 3_600_000) / 60_000
        let s = (clamped % 60_000) / 1000
        let remainder = clamped % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, remainder)
    }

    private static func parseTime(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ":")
        let parts = trimmed.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        return parts[0] * 3_600_000 + parts[1] * 60_000 + parts[2] * 1000 + parts[3]
    }
}
