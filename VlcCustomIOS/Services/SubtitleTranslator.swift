import Foundation

/// Translates subtitle lines (when Claude is not the chosen translator): Apple's on-device translation (iOS 18+), or a
/// self-hosted LibreTranslate server when one is set in the dialog. The App Store build has no Google: its free web
/// endpoint is not meant for apps (and may stop answering at any time).
enum SubtitleTranslator {
    struct TranslateError: LocalizedError {
        let message: String
        /// The service said "too many requests / quota used up": wait and try again later, the text itself is fine.
        let isRateLimited: Bool
        var errorDescription: String? { message }
    }

    /// Several subtitle lines at once, same count back. `from` "auto" (or empty): detected.
    static func translateLines(_ lines: [String], from: String, to: String, serverURL: String) async throws -> [String] {
        let clean = lines.map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
        guard !clean.isEmpty else { return [] }
        let server = serverURL.trimmingCharacters(in: .whitespaces)
        if !server.isEmpty, !server.contains("libretranslate.com") {
            var out: [String] = []
            for line in clean { out.append(try await libre(line, from: from, to: to, server: server)) }
            return out
        }
        return try await AppleTranslator.translate(clean, from: from, to: to)
    }

    private static func libre(_ text: String, from: String, to: String, server: String) async throws -> String {
        guard var components = URLComponents(string: server) else {
            throw TranslateError(message: "URL máy chủ dịch không hợp lệ.", isRateLimited: false)
        }
        components.path = components.path.hasSuffix("/translate") ? components.path : (components.path + "/translate")
        guard let url = components.url else {
            throw TranslateError(message: "URL máy chủ dịch không hợp lệ.", isRateLimited: false)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["q": text, "source": from, "target": to, "format": "text"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let translated = json["translatedText"] as? String else {
            throw TranslateError(message: "Không đọc được kết quả dịch.", isRateLimited: false)
        }
        return translated
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 429, 403, 503:
            throw TranslateError(message: "Dịch vụ dịch tạm hết lượt (mã \(http.statusCode)).", isRateLimited: true)
        default:
            throw TranslateError(message: "Máy chủ dịch trả lỗi (mã \(http.statusCode)).", isRateLimited: false)
        }
    }
}
