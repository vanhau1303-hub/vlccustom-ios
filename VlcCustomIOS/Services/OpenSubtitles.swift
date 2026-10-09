import Foundation
import Security

/// Subtitles from OpenSubtitles.com (REST API v1). The user's own free API key (opensubtitles.com → API consumers)
/// and, optionally, their account (more downloads per day) — kept in the Keychain.
///
/// Search: by the file's OpenSubtitles hash (size + the first and last 64 KB, read over SMB — an exact match for
/// that very release) together with a title / season / episode guessed from the file name. Download: a temporary
/// link from /download, then the file itself; kept in the app's cache so the same subtitle never costs a second
/// download.
enum OpenSubtitles {
    struct Result: Identifiable, Hashable {
        let fileId: Int
        let language: String
        let release: String
        let fileName: String
        let downloads: Int
        let hashMatch: Bool
        let hearingImpaired: Bool
        let machineTranslated: Bool
        var id: Int { fileId }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let base = "https://api.opensubtitles.com/api/v1"
    private static var userAgent: String {
        "VLCcustom v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")"
    }

    // MARK: - Settings (Keychain / UserDefaults)

    static var apiKey: String {
        get { Keychain.get("api-key") }
        set { Keychain.set(newValue, for: "api-key"); token = nil }
    }
    static var username: String {
        get { UserDefaults.standard.string(forKey: "opensubtitles_user") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "opensubtitles_user"); token = nil }
    }
    static var password: String {
        get { Keychain.get("password") }
        set { Keychain.set(newValue, for: "password"); token = nil }
    }
    static var isConfigured: Bool { !apiKey.isEmpty }

    /// Login token for this app session (and the API host the login told us to use).
    private static var token: String?
    private static var host = base

    // MARK: - Search

    /// `languages`: "vi,en" style (ISO 639-1).
    static func search(host smbHost: String, path: String, languages: String) async throws -> [Result] {
        guard isConfigured else { throw Failure(message: "Chưa nhập API key OpenSubtitles.") }
        let name = (path as NSString).lastPathComponent
        let guess = TitleGuess(fileName: name)
        var items = [URLQueryItem(name: "languages", value: languages)]
        if let hash = await movieHash(host: smbHost, path: path) {
            items.append(URLQueryItem(name: "moviehash", value: hash))
        }
        items.append(URLQueryItem(name: "query", value: guess.query.lowercased()))
        if let season = guess.season, let episode = guess.episode {
            items.append(URLQueryItem(name: "season_number", value: String(season)))
            items.append(URLQueryItem(name: "episode_number", value: String(episode)))
        }
        // The API wants its parameters sorted (it redirects otherwise).
        items.sort { $0.name < $1.name }
        var components = URLComponents(string: base + "/subtitles")!
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        prepare(&request)
        let json = try await send(request)
        let data = json["data"] as? [[String: Any]] ?? []
        var results: [Result] = []
        for item in data {
            guard let attributes = item["attributes"] as? [String: Any],
                  let files = attributes["files"] as? [[String: Any]], let first = files.first,
                  let fileId = first["file_id"] as? Int else { continue }
            results.append(Result(
                fileId: fileId,
                language: attributes["language"] as? String ?? "?",
                release: attributes["release"] as? String ?? (first["file_name"] as? String ?? ""),
                fileName: first["file_name"] as? String ?? "",
                downloads: attributes["download_count"] as? Int ?? 0,
                hashMatch: attributes["moviehash_match"] as? Bool ?? false,
                hearingImpaired: attributes["hearing_impaired"] as? Bool ?? false,
                machineTranslated: (attributes["machine_translated"] as? Bool ?? false) || (attributes["ai_translated"] as? Bool ?? false)
            ))
        }
        // Exact file matches first, then the most downloaded.
        return results.sorted {
            if $0.hashMatch != $1.hashMatch { return $0.hashMatch }
            return $0.downloads > $1.downloads
        }
    }

    // MARK: - Download

    /// The subtitle's lines (from the cache when it was downloaded before) and, after a real download, what the
    /// account has left for today.
    static func download(_ result: Result) async throws -> (lines: [TimedLine], note: String?) {
        let cached = cacheDirectory.appendingPathComponent("\(result.fileId).sub")
        if let data = try? Data(contentsOf: cached) {
            return (parse(data, fileName: result.fileName), nil)
        }
        try await loginIfNeeded()
        var request = URLRequest(url: URL(string: host + "/download")!)
        request.httpMethod = "POST"
        prepare(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["file_id": result.fileId])
        let json = try await send(request)
        guard let link = (json["link"] as? String).flatMap(URL.init(string:)) else {
            throw Failure(message: (json["message"] as? String) ?? "OpenSubtitles không trả về link tải.")
        }
        let (data, response) = try await URLSession.shared.data(from: link)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure(message: "Tải phụ đề lỗi (mã \(http.statusCode)).")
        }
        try? data.write(to: cached)
        let lines = parse(data, fileName: json["file_name"] as? String ?? result.fileName)
        guard !lines.isEmpty else { throw Failure(message: "File phụ đề trống hoặc không đọc được.") }
        var note: String?
        if let remaining = json["remaining"] as? Int {
            note = "Còn \(remaining) lượt tải hôm nay."
        }
        PlaybackDiagnostics.append("opensubtitles: downloaded \(result.fileId) (\(result.language)) — \(note ?? "")")
        return (lines, note)
    }

    private static func parse(_ data: Data, fileName: String) -> [TimedLine] {
        let text = ExistingSubtitles.decode(data)
        let ext = (fileName as NSString).pathExtension.lowercased()
        let raw = ext == "ass" || ext == "ssa" ? ExistingSubtitles.parseAss(text) : ExistingSubtitles.parseSrtOrVtt(text)
        return ExistingSubtitles.finish(raw)
    }

    private static let cacheDirectory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("opensubtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - HTTP

    private static func prepare(_ request: inout URLRequest) {
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if request.httpMethod == "POST" { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse else { return json }
        let message = (json["message"] as? String) ?? (json["errors"] as? [String])?.joined(separator: " ") ?? ""
        switch http.statusCode {
        case 200..<300: return json
        case 401: throw Failure(message: "API key hoặc tài khoản OpenSubtitles không đúng. \(message)")
        case 403: throw Failure(message: "OpenSubtitles từ chối (403). \(message)")
        case 406: throw Failure(message: "Hết lượt tải phụ đề hôm nay. \(message)")
        case 429: throw Failure(message: "OpenSubtitles đang giới hạn, thử lại sau ít phút.")
        default: throw Failure(message: "OpenSubtitles lỗi \(http.statusCode). \(message)")
        }
    }

    /// Logs in once per app session when an account is set (anonymous downloads are far more limited).
    private static func loginIfNeeded() async throws {
        guard token == nil, !username.isEmpty, !password.isEmpty else { return }
        var request = URLRequest(url: URL(string: base + "/login")!)
        request.httpMethod = "POST"
        prepare(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        let json = try await send(request)
        token = json["token"] as? String
        if let baseURL = json["base_url"] as? String, !baseURL.isEmpty {
            host = baseURL.hasPrefix("http") ? baseURL + "/api/v1" : "https://\(baseURL)/api/v1"
        }
    }

    /// Checks the key (and the account) from the settings: a tiny search, then a login.
    static func check() async -> String {
        do {
            var components = URLComponents(string: base + "/subtitles")!
            components.queryItems = [URLQueryItem(name: "languages", value: "en"), URLQueryItem(name: "query", value: "matrix")]
            var request = URLRequest(url: components.url!)
            prepare(&request)
            _ = try await send(request)
            token = nil
            try await loginIfNeeded()
            return username.isEmpty ? "API key dùng được ✓ (chưa đăng nhập: ít lượt tải hơn)" : "API key và tài khoản dùng được ✓"
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - OpenSubtitles hash

    /// File size + the 64-bit little-endian sum of the first and last 64 KB, as 16 hex digits.
    static func movieHash(host: String, path: String) async -> String? {
        guard let connection = await SmbRegistry.shared.getOrReconnect(host),
              let size = try? await connection.fileSize(path: path), size >= 131_072,
              let head = try? await connection.readChunk(path: path, offset: 0, count: 65_536),
              let tail = try? await connection.readChunk(path: path, offset: size - 65_536, count: 65_536),
              head.count == 65_536, tail.count == 65_536 else { return nil }
        var hash = UInt64(bitPattern: size)
        for chunk in [head, tail] {
            chunk.withUnsafeBytes { raw in
                for i in stride(from: 0, to: 65_536, by: 8) {
                    hash = hash &+ UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt64.self))
                }
            }
        }
        return String(format: "%016llx", hash)
    }

    // MARK: - Keychain

    private enum Keychain {
        static let service = "com.vlccustom.ios.opensubtitles"
        static func get(_ account: String) -> String {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: account, kSecReturnData as String: true]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        static func set(_ value: String, for account: String) {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: account]
            SecItemDelete(query as CFDictionary)
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            var add = query
            add[kSecValueData as String] = Data(trimmed.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// Title / season / episode from a release file name: "Family.Guy.S18E17.Coma.Guy.1080p.WEB-DL.x265.mkv" →
/// "Family Guy", 18, 17; "Parasite.2019.KOREAN.1080p.BluRay.x264.mkv" → "Parasite 2019".
struct TitleGuess {
    let query: String
    let season: Int?
    let episode: Int?

    init(fileName: String) {
        var base = (fileName as NSString).deletingPathExtension
        base = base.replacingOccurrences(of: "[._]", with: " ", options: .regularExpression)
        base = base.replacingOccurrences(of: "\\[[^\\]]*\\]|\\([^)]*vietsub[^)]*\\)", with: " ", options: [.regularExpression, .caseInsensitive])
        base = base.replacingOccurrences(of: "[()\\[\\]{}]", with: " ", options: .regularExpression)
        if let match = base.range(of: "(?i)\\bS(\\d{1,2})\\s?E(\\d{1,3})\\b", options: .regularExpression) {
            let token = String(base[match])
            let numbers = token.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.compactMap(Int.init)
            season = numbers.first
            episode = numbers.count > 1 ? numbers[1] : nil
            base = String(base[..<match.lowerBound])
        } else {
            season = nil
            episode = nil
            // A movie: keep the title and the year, drop the release details after it.
            if let year = base.range(of: "\\b(19|20)\\d{2}\\b", options: .regularExpression) {
                base = String(base[..<year.upperBound])
            } else if let tag = base.range(of: "(?i)\\b(480p|720p|1080p|2160p|4k|bluray|web-?dl|webrip|hdtv|x264|x265|hevc|remux)\\b", options: .regularExpression) {
                base = String(base[..<tag.lowerBound])
            }
        }
        query = base.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
