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

    private enum Keys {
        static let modelSize = "speech_model_size"
        static let spokenLanguage = "speech_spoken_language"
        static let translateTo = "speech_translate_to"
        static let dualSubtitles = "speech_dual_subtitles"
        static let libreServer = "speech_libre_server"
    }

    private init() {
        let defaults = UserDefaults.standard
        modelSize = WhisperModelSize(rawValue: defaults.string(forKey: Keys.modelSize) ?? "") ?? .base
        spokenLanguage = defaults.string(forKey: Keys.spokenLanguage)
        translateTo = defaults.string(forKey: Keys.translateTo)
        dualSubtitles = defaults.bool(forKey: Keys.dualSubtitles)
        libreTranslateServer = defaults.string(forKey: Keys.libreServer) ?? "https://libretranslate.com"
    }
}
