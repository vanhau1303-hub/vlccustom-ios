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
    /// Who translates: Apple's on-device translation (iOS 18+), or Claude (the user's own API key) in a chosen style.
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
        useClaude ? "claude:\(claudeModel.rawValue):\(translationStyle.rawValue)" : "apple"
    }

    /// The model that suits this iPhone: Turbo with 8 GB of RAM, Small with 6 GB, Base below. Used until the user
    /// picks one.
    static var recommendedModel: WhisperModelSize {
        let ram = ProcessInfo.processInfo.physicalMemory
        if ram >= 7_500_000_000 { return .turbo }
        if ram >= 5_500_000_000 { return .small }
        return .base
    }

    // MARK: - Per folder ("theo lần trước")
    //
    // A series lives in one folder: the language, translator, style and model used there are remembered and put
    // back when a video of that folder opens the AI subtitle sheet (or the next episode continues on its own).

    private struct FolderPrefs: Codable {
        var spoken: String?
        var translateTo: String?
        var dual: Bool
        var useClaude: Bool
        var claudeModel: String
        var style: String
        var model: String
        var at: Date
    }

    private static func folderKey(_ source: String) -> String {
        (source as NSString).deletingLastPathComponent
    }

    private var folderPrefs: [String: FolderPrefs] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Keys.folderPrefs) else { return [:] }
            return (try? JSONDecoder().decode([String: FolderPrefs].self, from: data)) ?? [:]
        }
        set {
            var all = newValue
            if all.count > 200 {
                for (key, _) in all.sorted(by: { $0.value.at < $1.value.at }).prefix(all.count - 200) { all[key] = nil }
            }
            if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: Keys.folderPrefs) }
        }
    }

    func saveFolderPreferences(for source: String) {
        var all = folderPrefs
        all[Self.folderKey(source)] = FolderPrefs(spoken: spokenLanguage, translateTo: translateTo, dual: dualSubtitles,
                                                  useClaude: useClaude, claudeModel: claudeModel.rawValue,
                                                  style: translationStyle.rawValue, model: modelSize.rawValue, at: Date())
        folderPrefs = all
    }

    func applyFolderPreferences(for source: String) {
        guard let saved = folderPrefs[Self.folderKey(source)] else { return }
        if spokenLanguage != saved.spoken { spokenLanguage = saved.spoken }
        if translateTo != saved.translateTo { translateTo = saved.translateTo }
        if dualSubtitles != saved.dual { dualSubtitles = saved.dual }
        if useClaude != saved.useClaude { useClaude = saved.useClaude }
        if let model = ClaudeTranslator.Model(rawValue: saved.claudeModel), model != claudeModel { claudeModel = model }
        if let style = ClaudeTranslator.Style(rawValue: saved.style), style != translationStyle { translationStyle = style }
        if let size = WhisperModelSize(rawValue: saved.model), size != modelSize { modelSize = size }
    }

    private enum Keys {
        static let folderPrefs = "speech_folder_prefs"
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
        modelSize = WhisperModelSize(rawValue: defaults.string(forKey: Keys.modelSize) ?? "") ?? Self.recommendedModel
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
