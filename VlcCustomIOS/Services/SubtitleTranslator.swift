import Foundation

/// Translates text via a LibreTranslate-compatible HTTP server (self-hosted or the public instance). Chosen over
/// Apple's on-device Translation framework because that framework needs iOS 17.4+ and this app targets iOS 16, and
/// over Google ML Kit (what the Android app uses) because it has no iOS SDK — this is the closest realistic
/// equivalent that still works fully offline if the user points it at their own LibreTranslate server.
enum SubtitleTranslator {
    struct TranslateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func translate(_ text: String, from: String, to: String, serverURL: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        let base = serverURL.trimmingCharacters(in: .whitespaces)
        guard var components = URLComponents(string: base) else {
            throw TranslateError(message: "URL máy chủ dịch không hợp lệ.")
        }
        components.path = components.path.hasSuffix("/translate") ? components.path : (components.path + "/translate")
        guard let url = components.url else {
            throw TranslateError(message: "URL máy chủ dịch không hợp lệ.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["q": trimmed, "source": from, "target": to, "format": "text"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw TranslateError(message: "Máy chủ dịch trả lỗi.")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let translated = json["translatedText"] as? String else {
            throw TranslateError(message: "Không đọc được kết quả dịch.")
        }
        return translated
    }
}
