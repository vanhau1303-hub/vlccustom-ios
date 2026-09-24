import Foundation

/// Translates subtitle lines. Default engine: Google Translate's free web endpoint (no API key). The public
/// libretranslate.com instance this used before now requires a paid API key, so every request failed — and the
/// failure was swallowed, which is why translated subtitles never appeared. A self-hosted LibreTranslate server can
/// still be set in the dialog and is used instead when present.
enum SubtitleTranslator {
    struct TranslateError: LocalizedError {
        let message: String
        /// The service said "too many requests / quota used up": wait and try again later, the text itself is fine.
        let isRateLimited: Bool
        var errorDescription: String? { message }
    }

    static func translate(_ text: String, from: String, to: String, serverURL: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        let server = serverURL.trimmingCharacters(in: .whitespaces)
        if server.isEmpty || server.contains("libretranslate.com") {
            return try await google(trimmed, from: from, to: to)
        }
        return try await libre(trimmed, from: from, to: to, server: server)
    }

    private static func google(_ text: String, from: String, to: String) async throws -> String {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: from.isEmpty ? "auto" : from),
            URLQueryItem(name: "tl", value: to),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        guard let url = components.url else { throw TranslateError(message: "Không tạo được yêu cầu dịch.", isRateLimited: false) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response)
        // [[["translated","original",...], ...], ...] — one entry per sentence.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let sentences = root.first as? [Any] else {
            throw TranslateError(message: "Không đọc được kết quả dịch.", isRateLimited: false)
        }
        let translated = sentences.compactMap { ($0 as? [Any])?.first as? String }.joined()
        guard !translated.isEmpty else { throw TranslateError(message: "Kết quả dịch trống.", isRateLimited: false) }
        return translated
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
