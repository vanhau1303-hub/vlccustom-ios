import Foundation
import SwiftUI
import Translation

/// Apple's own translation (iOS 18+): on the device, free, no account or key, nothing sent to a translation
/// company. The first time a language pair is used iOS asks to download it (a system sheet over the player).
enum AppleTranslator {
    static var isAvailable: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    /// Several subtitle lines, same count back.
    static func translate(_ lines: [String], from source: String?, to target: String) async throws -> [String] {
        guard #available(iOS 18.0, *) else {
            throw SubtitleTranslator.TranslateError(
                message: "Bộ dịch của Apple cần iOS 18 trở lên — chọn Claude trong \"Cách dịch\" để dịch.",
                isRateLimited: false)
        }
        return try await AppleTranslationBridge.shared.translate(lines, from: source, to: target)
    }

    /// Apple's language for one of ours ("zh" is written in simplified Chinese).
    static func language(_ code: String) -> Locale.Language {
        Locale.Language(identifier: code == "zh" ? "zh-Hans" : code)
    }
}

/// Apple's translation sessions only exist inside a SwiftUI `.translationTask`, so `AppleTranslationHost` (an
/// invisible view in the player) keeps one open for the languages asked for and serves the queued requests with it.
@available(iOS 18.0, *)
@MainActor
final class AppleTranslationBridge: ObservableObject {
    static let shared = AppleTranslationBridge()

    @Published private(set) var configuration: TranslationSession.Configuration?

    private struct Job {
        let lines: [String]
        let source: Locale.Language?
        let target: Locale.Language
        let continuation: CheckedContinuation<[String], Error>
    }

    private var jobs: [Job] = []
    private var serving = false
    private var hosts = 0

    func translate(_ lines: [String], from sourceCode: String?, to targetCode: String) async throws -> [String] {
        guard hosts > 0 else {
            throw SubtitleTranslator.TranslateError(message: "Bộ dịch của Apple chỉ chạy khi trình phát đang mở.",
                                                    isRateLimited: false)
        }
        let code = sourceCode.flatMap { $0.isEmpty || $0 == "auto" ? nil : $0 }
        let source = code.map(AppleTranslator.language)
        let target = AppleTranslator.language(targetCode)
        if let source, await LanguageAvailability().status(from: source, to: target) == .unsupported {
            throw SubtitleTranslator.TranslateError(
                message: "Bộ dịch của Apple chưa dịch được \(code ?? "") → \(targetCode). Chọn Claude trong \"Cách dịch\".",
                isRateLimited: false)
        }
        return try await withCheckedThrowingContinuation { continuation in
            jobs.append(Job(lines: lines, source: source, target: target, continuation: continuation))
            if !serving { open(source: source, target: target) }
        }
    }

    /// Asks the host for a session for these languages (a new configuration, or the same one run again).
    private func open(source: Locale.Language?, target: Locale.Language) {
        if var current = configuration, current.source == source, current.target == target {
            current.invalidate()
            configuration = current
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    /// The host's `.translationTask` with a live session: every queued request for its languages, then the next
    /// languages asked for (if any).
    func serve(_ session: TranslationSession) async {
        guard let config = configuration else { return }
        serving = true
        while let index = jobs.firstIndex(where: { $0.source == config.source && $0.target == config.target }) {
            let job = jobs.remove(at: index)
            do {
                let requests = job.lines.enumerated().map {
                    TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
                }
                let responses = try await session.translations(from: requests)
                var out = job.lines
                for response in responses {
                    if let id = response.clientIdentifier.flatMap(Int.init), id < out.count { out[id] = response.targetText }
                }
                job.continuation.resume(returning: out)
            } catch {
                job.continuation.resume(throwing: SubtitleTranslator.TranslateError(
                    message: "Bộ dịch của Apple: \(error.localizedDescription)", isRateLimited: false))
            }
        }
        serving = false
        if let next = jobs.first { open(source: next.source, target: next.target) }
    }

    func hostAppeared() { hosts += 1 }

    func hostDisappeared() {
        hosts = max(0, hosts - 1)
        guard hosts == 0 else { return }
        // Nobody left to translate with: whatever waits fails now (it is queued again and retried later).
        let waiting = jobs
        jobs = []
        configuration = nil
        for job in waiting {
            job.continuation.resume(throwing: SubtitleTranslator.TranslateError(message: "Đã đóng trình phát.",
                                                                                isRateLimited: false))
        }
    }
}

/// Invisible; keeps Apple's translation session for `AppleTranslationBridge` (and its download sheet) in the player.
@available(iOS 18.0, *)
struct AppleTranslationHost: View {
    @ObservedObject private var bridge = AppleTranslationBridge.shared

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .translationTask(bridge.configuration) { session in
                await bridge.serve(session)
            }
            .onAppear { bridge.hostAppeared() }
            .onDisappear { bridge.hostDisappeared() }
    }
}
