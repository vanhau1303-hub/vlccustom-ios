import Foundation

/// Splits a "smb://host/share/path/file.ext" source string (the convention used across `VideoItem`/`AudioItem`/
/// `ImageItem`) into the host and the share-relative path `SmbConnection` expects.
enum SmbUri {
    static func parse(_ source: String) -> (host: String, path: String)? {
        guard source.hasPrefix("smb://") else { return nil }
        let withoutScheme = source.dropFirst("smb://".count)
        guard let slash = withoutScheme.firstIndex(of: "/") else { return nil }
        let host = String(withoutScheme[withoutScheme.startIndex..<slash])
        let path = String(withoutScheme[withoutScheme.index(after: slash)...])
        return (host, path)
    }
}
