import Foundation

/// One AI-generated (or AI-translated) subtitle line, timed in milliseconds from the start of the video.
struct LiveCue: Identifiable, Hashable {
    var id: Int { startMs }
    let startMs: Int
    let endMs: Int
    let text: String
}

struct SubtitleLanguage: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }
}

/// Matches the language picker offered by the Android app's AI-subtitle dialog.
let subtitleLanguages: [SubtitleLanguage] = [
    .init(code: "vi", name: "Tiếng Việt"),
    .init(code: "en", name: "Tiếng Anh"),
    .init(code: "zh", name: "Tiếng Trung"),
    .init(code: "ja", name: "Tiếng Nhật"),
    .init(code: "ko", name: "Tiếng Hàn"),
    .init(code: "fr", name: "Tiếng Pháp"),
    .init(code: "de", name: "Tiếng Đức"),
    .init(code: "es", name: "Tiếng Tây Ban Nha"),
    .init(code: "pt", name: "Tiếng Bồ Đào Nha"),
    .init(code: "ru", name: "Tiếng Nga"),
    .init(code: "th", name: "Tiếng Thái"),
    .init(code: "id", name: "Tiếng Indonesia"),
    .init(code: "it", name: "Tiếng Ý"),
    .init(code: "ar", name: "Tiếng Ả Rập"),
    .init(code: "hi", name: "Tiếng Hindi"),
    .init(code: "tr", name: "Tiếng Thổ Nhĩ Kỳ"),
]

/// WhisperKit downloads a Core ML model named by these variants from `argmaxinc/whisperkit-coreml` on first use.
enum WhisperModelSize: String, CaseIterable, Identifiable {
    case tiny, base, small

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tiny: return "Tiny (nhanh, kém chính xác hơn)"
        case .base: return "Base"
        case .small: return "Small (chính xác hơn, tải mô hình lâu hơn)"
        }
    }
}
