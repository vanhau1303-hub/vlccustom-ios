import Foundation
import WhisperKit

/// Loads (downloading the Core ML model from `argmaxinc/whisperkit-coreml` on first use, then reusing the on-disk
/// cache) one `WhisperKit` instance per model size, and keeps it around for the rest of the app session.
actor WhisperEngine {
    static let shared = WhisperEngine()

    private var instances: [String: WhisperKit] = [:]

    func instance(model: String) async throws -> WhisperKit {
        if let existing = instances[model] { return existing }
        let kit = try await WhisperKit(WhisperKitConfig(model: model, download: true))
        instances[model] = kit
        return kit
    }
}
