import Foundation
import Security

/// Subtitle translation with Claude (Anthropic Messages API, raw HTTP — there is no official Swift SDK), in a style
/// the user picks. The key is the user's own (console.anthropic.com), kept in the Keychain.
enum ClaudeTranslator {
    enum Model: String, CaseIterable, Identifiable {
        case opus = "claude-opus-5-5"
        case sonnet = "claude-sonnet-5-5"
        case haiku = "claude-haiku-4-5"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .opus: return "Claude Opus 5.5 (dịch hay nhất)"
            case .sonnet: return "Claude Sonnet 5.5 (cân bằng)"
            case .haiku: return "Claude Haiku 4.5 (rẻ, nhanh)"
            }
        }
    }

    enum Style: String, CaseIterable, Identifiable {
        case faithful, natural, funny
        var id: String { rawValue }
        var label: String {
            switch self {
            case .faithful: return "Sát nghĩa"
            case .natural: return "Tự nhiên"
            case .funny: return "Lầy lội / hài"
            }
        }
        var instruction: String {
            switch self {
            case .faithful:
                return "Translate as faithfully as natural phrasing allows: keep the exact meaning, names, register and tone; do not add or drop information and do not add jokes."
            case .natural:
                return "Translate the way a professional subtitler would: natural, fluent everyday speech, idioms adapted to their natural equivalent, meaning kept."
            case .funny:
                return "This is an irreverent adult animated comedy (think Family Guy). Translate in a cheeky, playful, slangy style so every joke, insult, sarcastic jab and pun lands for a native audience: use contemporary colloquial slang and natural swearing where the original has it, adapt puns and cultural references to ones the audience gets, keep each character's attitude. Stay true to what is being said — make it funnier only through wording, never by inventing new content."
            }
        }
    }

    struct TranslateError: LocalizedError {
        let message: String
        let isRateLimited: Bool
        var isLineCountMismatch = false
        var errorDescription: String? { message }
    }

    // MARK: - Key (Keychain)

    private static let service = "com.vlccustom.ios.anthropic"

    static var apiKey: String {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "api-key",
                kSecReturnData as String: true,
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        set {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "api-key",
            ]
            SecItemDelete(query as CFDictionary)
            let key = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            var add = query
            add[kSecValueData as String] = Data(key.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    // MARK: - Translation

    /// `lines` translated into `target`, same count and order. `context`: the lines just before them (already
    /// shown), so jokes and references running across lines are understood.
    static func translate(_ lines: [String], context: [String], to target: String, model: Model, style: Style) async throws -> [String] {
        let key = apiKey
        guard !key.isEmpty else { throw TranslateError(message: "Chưa nhập API key Claude.", isRateLimited: false) }
        let language = Locale(identifier: "en").localizedString(forLanguageCode: target) ?? target

        let system = """
        You translate TV/film subtitles into \(language). \(style.instruction)
        Each input line is one subtitle as it appears on screen; keep each translation short enough to read as a subtitle (about two lines). \
        Return exactly one translation per input line, in the same order, without numbering, quotes or notes. \
        Lines can be speech-recognition output with mistakes: translate what was most likely said.
        """
        var user = ""
        if !context.isEmpty {
            user += "Previous lines, for context only (do not translate):\n" + context.joined(separator: "\n") + "\n\n"
        }
        user += "Translate these \(lines.count) lines:\n"
        for (i, line) in lines.enumerated() { user += "\(i + 1). \(line)\n" }

        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 16000,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "output_config": outputConfig(for: model),
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if model != .haiku {
            // A request a safety classifier declines is re-run server-side on the model Anthropic recommends.
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let detail = ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
            switch http.statusCode {
            case 401, 403:
                throw TranslateError(message: "API key Claude không hợp lệ hoặc không có quyền (\(http.statusCode)).", isRateLimited: false)
            case 429, 529, 503:
                throw TranslateError(message: "Claude đang quá tải / hết hạn mức (mã \(http.statusCode)).", isRateLimited: true)
            case 400 where detail.lowercased().contains("credit"):
                throw TranslateError(message: "Tài khoản Claude hết tiền (credit). \(detail)", isRateLimited: false)
            default:
                throw TranslateError(message: "Claude trả lỗi \(http.statusCode). \(detail)", isRateLimited: false)
            }
        }
        guard let json else { throw TranslateError(message: "Không đọc được trả lời của Claude.", isRateLimited: false) }
        let stop = json["stop_reason"] as? String
        if stop == "refusal" { throw TranslateError(message: "Claude từ chối dịch đoạn này.", isRateLimited: false) }
        if stop == "max_tokens" { throw TranslateError(message: "Trả lời của Claude bị cắt (quá dài).", isRateLimited: false) }
        let text = (json["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let translations = parsed["translations"] as? [String] else {
            throw TranslateError(message: "Claude trả về sai định dạng.", isRateLimited: false)
        }
        guard translations.count == lines.count else {
            throw TranslateError(message: "Claude trả về \(translations.count)/\(lines.count) dòng.", isRateLimited: false,
                                 isLineCountMismatch: true)
        }
        return translations.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// JSON output with exactly the translations; effort medium on the models that take it (Haiku 4.5 does not).
    private static func outputConfig(for model: Model) -> [String: Any] {
        var config: [String: Any] = [
            "format": [
                "type": "json_schema",
                "schema": [
                    "type": "object",
                    "properties": ["translations": ["type": "array", "items": ["type": "string"]]],
                    "required": ["translations"],
                    "additionalProperties": false,
                ] as [String: Any],
            ] as [String: Any],
        ]
        if model != .haiku { config["effort"] = "medium" }
        return config
    }

    /// A one-line request to check the key from the settings screen.
    static func check(model: Model) async -> String {
        do {
            let out = try await translate(["Hello there!"], context: [], to: "vi", model: model, style: .natural)
            return "Key dùng được ✓ (\"Hello there!\" → \"\(out.first ?? "")\")"
        } catch {
            return error.localizedDescription
        }
    }
}
