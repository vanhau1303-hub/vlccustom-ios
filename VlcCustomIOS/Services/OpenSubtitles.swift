import Foundation

/// Subtitles from OpenSubtitles.org through its public REST search (rest.opensubtitles.org) — no API key or
/// account, like the Android app. Checked by hand: a title search returns the subtitles with a direct gzip link.
///
/// - Exact match: the file's OpenSubtitles hash (size + the first and last 64 KB, read over SMB).
/// - Title: a series episode is searched by title + season + episode (the language filter does not work together
///   with those, so languages are filtered here); a movie by title per wanted language (one language per request).
/// - Download: the gzip link, unpacked and saved in the app's cache as a subtitle file the player loads like any
///   other subtitle track.
enum OpenSubtitles {
    struct Result: Identifiable, Hashable {
        let fileId: String
        let language: String       // "vi", "en"…
        let languageName: String
        let release: String
        let format: String         // "srt", "ass"…
        let downloads: Int
        let hashMatch: Bool
        let hearingImpaired: Bool
        let link: URL
        var id: String { fileId }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let base = "https://rest.opensubtitles.org/search"
    /// OpenSubtitles' user agent for apps without a registered one.
    private static let userAgent = "TemporaryUserAgent"

    /// ISO 639-1 ("vi") → the 3-letter ids the search takes ("vie").
    private static let threeLetter = ["vi": "vie", "en": "eng", "ja": "jpn", "ko": "kor", "zh": "chi", "fr": "fre",
                                      "de": "ger", "es": "spa", "th": "tha", "id": "ind", "ru": "rus", "pt": "por"]

    /// `languages`: wanted ISO 639-1 codes, most wanted first.
    static func search(host: String, path: String, languages: [String]) async throws -> [Result] {
        let guess = TitleGuess(fileName: (path as NSString).lastPathComponent)
        var requests: [String] = []
        if let (size, hash) = await fileHash(host: host, path: path) {
            requests.append("moviebytesize-\(size)/moviehash-\(hash)")
        }
        let query = "query-" + (guess.query.lowercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")
        if let season = guess.season, let episode = guess.episode {
            requests.append("episode-\(episode)/\(query)/season-\(season)")
        } else {
            for code in languages { requests.append("\(query)/sublanguageid-\(threeLetter[code] ?? code)") }
        }

        var found: [String: Result] = [:]
        var lastError: Error?
        for path in requests {
            do {
                for result in try await fetch(path) where found[result.fileId] == nil || result.hashMatch {
                    found[result.fileId] = result
                }
            } catch {
                lastError = error
            }
        }
        if found.isEmpty, let lastError { throw lastError }
        // Wanted languages only; exact file matches first, then by language order, then the most downloaded.
        let order = Dictionary(uniqueKeysWithValues: languages.enumerated().map { ($1, $0) })
        return found.values
            .filter { order[$0.language] != nil }
            .sorted {
                if $0.hashMatch != $1.hashMatch { return $0.hashMatch }
                let a = order[$0.language] ?? 99, b = order[$1.language] ?? 99
                if a != b { return a < b }
                return $0.downloads > $1.downloads
            }
    }

    private static func fetch(_ path: String) async throws -> [Result] {
        guard let url = URL(string: "\(base)/\(path)") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(userAgent, forHTTPHeaderField: "X-User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 429 { throw Failure(message: "OpenSubtitles đang giới hạn, thử lại sau ít phút.") }
            throw Failure(message: "OpenSubtitles lỗi \(http.statusCode).")
        }
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let fileId = item["IDSubtitleFile"] as? String,
                  let link = (item["SubDownloadLink"] as? String).flatMap(URL.init(string:)) else { return nil }
            let release = (item["MovieReleaseName"] as? String)?.trimmingCharacters(in: .whitespaces)
            return Result(
                fileId: fileId,
                language: (item["ISO639"] as? String ?? "").lowercased(),
                languageName: item["LanguageName"] as? String ?? "",
                release: (release?.isEmpty == false ? release : nil) ?? (item["SubFileName"] as? String ?? ""),
                format: (item["SubFormat"] as? String ?? "srt").lowercased(),
                downloads: Int(item["SubDownloadsCnt"] as? String ?? "") ?? 0,
                hashMatch: (item["MatchedBy"] as? String) == "moviehash",
                hearingImpaired: (item["SubHearingImpaired"] as? String) == "1",
                link: link)
        }
    }

    // MARK: - Download

    /// The subtitle as a local file (downloaded once, then from the cache), ready for the player.
    static func download(_ result: Result) async throws -> URL {
        let ext = ["srt", "ass", "ssa", "vtt", "sub"].contains(result.format) ? result.format : "srt"
        let file = cacheDirectory.appendingPathComponent("\(result.fileId).\(ext)")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        var request = URLRequest(url: result.link)
        request.timeoutInterval = 30
        request.setValue(userAgent, forHTTPHeaderField: "X-User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure(message: http.statusCode == 429 || http.statusCode == 407
                          ? "Đã tải quá nhiều phụ đề, OpenSubtitles tạm chặn — thử lại sau."
                          : "Tải phụ đề lỗi (mã \(http.statusCode)).")
        }
        guard let raw = gunzip(data) ?? (data.first == 0x31 || data.first == 0xEF ? data : nil) else {
            throw Failure(message: "Không giải nén được phụ đề.")
        }
        // Saved as UTF-8 whatever the original encoding (Vietnamese ones are often Windows-1258).
        let text = ExistingSubtitles.decode(raw)
        guard !text.isEmpty else { throw Failure(message: "File phụ đề trống.") }
        try Data(text.utf8).write(to: file, options: .atomic)
        PlaybackDiagnostics.append("opensubtitles: \(result.fileId) (\(result.language)) \(result.release)")
        return file
    }

    private static let cacheDirectory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("opensubtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// gzip → bytes (header and trailer stripped, the deflate stream inflated with Apple's zlib).
    private static func gunzip(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 { guard i + 2 <= b.count else { return nil }; i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8) }
        if flags & 0x08 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        let deflate = Data(b[i..<(b.count - 8)])
        return try? (deflate as NSData).decompressed(using: .zlib) as Data
    }

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
