import Foundation

/// Reading-comfort rules applied to AI-generated cues — a straight port of the Android app's `SubtitleLayout`
/// (same line-length cap and reading-speed formula), kept as pure functions with no external dependency.
enum SubtitleLayout {
    static let maxLineChars = 42
    static let charsPerSecond: Double = 17
    static let minMs = 900
    static let maxMs = 6_000
    static let maxHoldMs = 500

    /// Breaks a line longer than `maxLineChars` into two, at the space nearest the midpoint.
    static func wrap(_ text: String) -> String {
        guard text.count > maxLineChars else { return text }
        let chars = Array(text)
        let mid = chars.count / 2
        var bestIndex: Int?
        var bestDistance = Int.max
        for (i, char) in chars.enumerated() where char == " " {
            let distance = abs(i - mid)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = i
            }
        }
        guard let splitIndex = bestIndex else { return text }
        let first = String(chars[0..<splitIndex])
        let second = String(chars[(splitIndex + 1)...])
        return first + "\n" + second
    }

    /// End time for a cue given its recognized end, clamped to a comfortable reading duration.
    static func endFor(startMs: Int, recognizedEndMs: Int, text: String) -> Int {
        let readingMs = Int(Double(text.count) / charsPerSecond * 1000)
        let byReading = startMs + max(minMs, min(maxMs, readingMs))
        let byHold = recognizedEndMs + maxHoldMs
        return min(byReading, byHold)
    }
}
