import Foundation

/// Persisted choices for the AI-subtitle dialog, so they carry over between videos and app launches (same idea as
/// the Android app's `SubtitleSettings`).
final class SpeechSettings: ObservableObject {
    static let shared = SpeechSettings()

    @Published var modelSize: WhisperModelSize {
        didSet { UserDefaults.standard.set(modelSize.rawValue, forKey: Keys.modelSize) }
    }
    @Published var spokenLanguage: String? {
        didSet { UserDefaults.standard.set(spokenLanguage, forKey: Keys.spokenLanguage) }
    }
    @Published var translateTo: String? {
        didSet { UserDefaults.standard.set(translateTo, forKey: Keys.translateTo) }
    }
    @Published var dualSubtitles: Bool {
        didSet { UserDefaults.standard.set(dualSubtitles, forKey: Keys.dualSubtitles) }
    }
    @Published var libreTranslateServer: String {
        didSet { UserDefaults.standard.set(libreTranslateServer, forKey: Keys.libreServer) }
    }
    /// Who translates: Google's free endpoint, or Claude (the user's own API key) in a chosen style.
    @Published var useClaude: Bool {
        didSet { UserDefaults.standard.set(useClaude, forKey: Keys.useClaude) }
    }
    @Published var claudeModel: ClaudeTranslator.Model {
        didSet { UserDefaults.standard.set(claudeModel.rawValue, forKey: Keys.claudeModel) }
    }
    @Published var translationStyle: ClaudeTranslator.Style {
        didSet { UserDefaults.standard.set(translationStyle.rawValue, forKey: Keys.style) }
    }

    /// Part of the subtitle cache key: a change of translator or style makes new subtitles instead of reusing others.
    var translatorSignature: String {
        useClaude ? "claude:\(claudeModel.rawValue):\(translationStyle.rawValue)" : "google"
    }

    private enum Keys {
        static let modelSize = "speech_model_size"
        static let spokenLanguage = "speech_spoken_language"
        static let translateTo = "speech_translate_to"
        static let dualSubtitles = "speech_dual_subtitles"
        static let libreServer = "speech_libre_server"
        static let useClaude = "speech_use_claude"
        static let claudeModel = "speech_claude_model"
        static let style = "speech_translation_style"
    }

    private init() {
        let defaults = UserDefaults.standard
        modelSize = WhisperModelSize(rawValue: defaults.string(forKey: Keys.modelSize) ?? "") ?? .base
        spokenLanguage = defaults.string(forKey: Keys.spokenLanguage)
        translateTo = defaults.string(forKey: Keys.translateTo)
        dualSubtitles = defaults.bool(forKey: Keys.dualSubtitles)
        // Empty = Google's free endpoint. The old default (libretranslate.com) now needs a paid key, so it is
        // treated as empty too.
        let savedServer = defaults.string(forKey: Keys.libreServer) ?? ""
        libreTranslateServer = savedServer.contains("libretranslate.com") ? "" : savedServer
        useClaude = defaults.bool(forKey: Keys.useClaude)
        claudeModel = ClaudeTranslator.Model(rawValue: defaults.string(forKey: Keys.claudeModel) ?? "") ?? .opus
        translationStyle = ClaudeTranslator.Style(rawValue: defaults.string(forKey: Keys.style) ?? "") ?? .natural
    }
}
