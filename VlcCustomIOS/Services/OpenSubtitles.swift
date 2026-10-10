import Foundation

/// Subtitles from OpenSubtitles.com through its official REST API (api.opensubtitles.com/api/v1), the cheapest way:
/// - searching is free with the app's API key (from the build: `LAN_OPENSUBTITLES_KEY`; test builds can also take
///   one typed in Cài đặt → Phụ đề);
/// - downloads count against the *user's* own OpenSubtitles account when they log in (free accounts: about 20 a
///   day), otherwise against a small daily allowance — never against a paid plan of ours.
///
/// - Exact match: the file's OpenSubtitles hash (size + the first and last 64 KB, read over SMB).
/// - Title: guessed from the file name (series: title + season + episode).
/// - Download: the API hands out a one-time link to the file; it is saved in the app's cache as UTF-8 and shown by
///   the app like the AI subtitles.
enum OpenSubtitles {
    /// `LiveSubtitles.existingID` of a downloaded subtitle: this + the file id.
    static let optionPrefix = "opensubtitles:"

    struct Result: Identifiable, Hashable {
        let fileId: String
        let language: String       // "vi", "en"…
        let release: String
        let format: String         // "srt", "ass"…
        let downloads: Int
        let hashMatch: Bool
        let hearingImpaired: Bool
        var id: String { fileId }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let api = "https://api.opensubtitles.com/api/v1"
    /// The name and version the app is registered under at OpenSubtitles ("AppName vX.Y").
    private static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "LANPlayer v\(version)"
    }

    /// The app's API key: the build's, else (test builds) one typed in the settings.
    static var apiKey: String {
        let built = (Bundle.main.object(forInfoDictionaryKey: "LANOpenSubtitlesKey") as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
        if !built.isEmpty, !built.hasPrefix("$(") { return built }
        return OpenSubtitlesAccount.typedApiKey
    }

    /// `languages`: wanted ISO 639-1 codes, most wanted first.
    static func search(host: String, path: String, languages: [String]) async throws -> [Result] {
        guard !apiKey.isEmpty else {
            throw Failure(message: "Bản này chưa có khoá OpenSubtitles (Cài đặt → Phụ đề → OpenSubtitles).")
        }
        let guess = TitleGuess(fileName: (path as NSString).lastPathComponent)
        let hash = await fileHash(host: host, path: path)
        var found = try await query(guess: guess, hash: hash?.1, languages: languages)
        if found.isEmpty, hash != nil {
            // Nothing by hash + title: the title alone.
            found = try await query(guess: guess, hash: nil, languages: languages)
        }
        let order = Dictionary(uniqueKeysWithValues: languages.enumerated().map { ($1, $0) })
        return found
            .filter { order[$0.language] != nil }
            .sorted {
                if $0.hashMatch != $1.hashMatch { return $0.hashMatch }
                let a = order[$0.language] ?? 99, b = order[$1.language] ?? 99
                if a != b { return a < b }
                return $0.downloads > $1.downloads
            }
    }

    /// One search. The API wants its parameters in alphabetical order, lowercase (it redirects otherwise).
    private static func query(guess: TitleGuess, hash: String?, languages: [String]) async throws -> [Result] {
        var items: [URLQueryItem] = []
        if let episode = guess.episode, guess.season != nil {
            items.append(URLQueryItem(name: "episode_number", value: String(episode)))
        }
        items.append(URLQueryItem(name: "languages", value: languages.map { $0.lowercased() }.sorted().joined(separator: ",")))
        if let hash { items.append(URLQueryItem(name: "moviehash", value: hash)) }
        items.append(URLQueryItem(name: "query", value: guess.query.lowercased()))
        if let season = guess.season, guess.episode != nil {
            items.append(URLQueryItem(name: "season_number", value: String(season)))
        }
        var components = URLComponents(string: "\(api)/subtitles")!
        components.queryItems = items
        guard let url = components.url else { return [] }
        let data = try await send(URLRequest(url: url), login: false)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let attributes = item["attributes"] as? [String: Any],
                  let file = (attributes["files"] as? [[String: Any]])?.first else { return nil }
            let fileId: String
            if let number = file["file_id"] as? Int {
                fileId = String(number)
            } else if let text = file["file_id"] as? String {
                fileId = text
            } else {
                return nil
            }
            let fileName = file["file_name"] as? String ?? ""
            let release = (attributes["release"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let ext = (fileName as NSString).pathExtension.lowercased()
            let language = (attributes["language"] as? String ?? "").lowercased()
            return Result(
                fileId: fileId,
                language: String(language.prefix(2)),
                release: release.isEmpty ? fileName : release,
                format: ext.isEmpty ? "srt" : ext,
                downloads: attributes["download_count"] as? Int ?? 0,
                hashMatch: attributes["moviehash_match"] as? Bool ?? false,
                hearingImpaired: attributes["hearing_impaired"] as? Bool ?? false)
        }
    }

    // MARK: - Download

    /// The subtitle as a local file (downloaded once, then from the cache), ready for the player.
    static func download(_ result: Result) async throws -> URL {
        let ext = ["srt", "ass", "ssa", "vtt", "sub"].contains(result.format) ? result.format : "srt"
        let file = cacheDirectory.appendingPathComponent("\(result.fileId).\(ext)")
        if FileManager.default.fileExists(atPath: file.path) { return file }

        var request = URLRequest(url: URL(string: "\(api)/download")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["file_id": Int(result.fileId) ?? 0])
        let reply = try await send(request, login: true)
        guard let json = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let link = (json["link"] as? String).flatMap(URL.init(string:)) else {
            throw Failure(message: "OpenSubtitles không trả về đường tải.")
        }
        if let remaining = json["remaining"] as? Int {
            await OpenSubtitlesAccount.shared.noteRemaining(remaining)
        }

        let (data, response) = try await URLSession.shared.data(from: link)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure(message: "Tải phụ đề lỗi (mã \(http.statusCode)).")
        }
        // Saved as UTF-8 whatever the original encoding (Vietnamese ones are often Windows-1258).
        let text = ExistingSubtitles.decode(data)
        guard !text.isEmpty else { throw Failure(message: "File phụ đề trống.") }
        try Data(text.utf8).write(to: file, options: .atomic)
        PlaybackDiagnostics.append("opensubtitles: \(result.fileId) (\(result.language)) \(result.release)")
        return file
    }

    /// Sends `request` with the app's key (and the user's login for downloads), mapping the API's errors to
    /// readable messages. A stale login is renewed once.
    private static func send(_ original: URLRequest, login: Bool, retried: Bool = false) async throws -> Data {
        var request = original
        request.timeoutInterval = 25
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if request.httpBody != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if login, let token = await OpenSubtitlesAccount.shared.token() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401 where login && !retried:
            await OpenSubtitlesAccount.shared.dropToken()
            return try await send(original, login: login, retried: true)
        case 406, 429:
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String
            let loggedIn = await OpenSubtitlesAccount.shared.isLoggedIn
            let hint = loggedIn ? "" : " Đăng nhập tài khoản OpenSubtitles miễn phí (Cài đặt → Phụ đề) để có thêm lượt."
            throw Failure(message: (message.map { "OpenSubtitles: \($0)" } ?? "Hết lượt tải phụ đề hôm nay.") + hint)
        default:
            throw Failure(message: "OpenSubtitles lỗi \(http.statusCode).")
        }
    }

    /// The lines of a downloaded file (saved as UTF-8 by `download`); empty for a format the app does not read.
    static func lines(of file: URL) -> [TimedLine] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let ext = file.pathExtension.lowercased()
        let raw: [TimedLine]
        switch ext {
        case "ass", "ssa": raw = ExistingSubtitles.parseAss(text)
        case "srt", "vtt": raw = ExistingSubtitles.parseSrtOrVtt(text)
        default: return []
        }
        return ExistingSubtitles.finish(raw)
    }

    private static let cacheDirectory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("opensubtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - OpenSubtitles hash

    /// (size, hash): size + the 64-bit little-endian sum of the first and last 64 KB, as 16 hex digits.
    static func fileHash(host: String, path: String) async -> (Int64, String)? {
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
        return (size, String(format: "%016llx", hash))
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
