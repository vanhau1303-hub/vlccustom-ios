import Foundation
import WhisperKit

/// Loads (downloading the Core ML model from `argmaxinc/whisperkit-coreml` on first use, then reusing the on-disk
/// cache) one `WhisperKit` instance per model size, and keeps it around for the rest of the app session.
actor WhisperEngine {
    static let shared = WhisperEngine()

    /// One load per model, shared by every caller — the AI subtitle dialog starts loading as soon as it opens, and
    /// "Bắt đầu" then waits on that same load instead of starting a second one.
    private var loads: [String: Task<WhisperKit, Error>] = [:]

    func instance(model: String) async throws -> WhisperKit {
        if let load = loads[model] { return try await load.value }
        let load = Task { try await WhisperKit(WhisperKitConfig(model: model, download: true)) }
        loads[model] = load
        do {
            let kit = try await load.value
            UserDefaults.standard.set(true, forKey: Self.downloadedKey(model))
            return kit
        } catch {
            loads[model] = nil
            throw error
        }
    }

    /// Starts loading a model that was already downloaded before, so it is ready by the time recognition starts.
    /// Never triggers a first download (hundreds of MB) by itself.
    func preloadIfDownloaded(model: String) async {
        guard UserDefaults.standard.bool(forKey: Self.downloadedKey(model)) else { return }
        _ = try? await instance(model: model)
    }

    private static func downloadedKey(_ model: String) -> String { "whisper_downloaded_\(model)" }
}
