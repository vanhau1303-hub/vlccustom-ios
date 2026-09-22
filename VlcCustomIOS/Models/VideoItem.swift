import Foundation

/// A playable video, either a local file (picked from the Files app) or one found on an SMB share.
struct VideoItem: Identifiable, Hashable {
    var id: String { source }
    let name: String
    /// A local file URL, or "smb://host/share/path/file.ext" for a network file.
    let source: String
    let sizeBytes: Int64
    let lastModified: Date

    var isSmb: Bool { source.hasPrefix("smb://") }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// One entry (file or folder) in an SMB directory listing.
struct SmbEntry: Identifiable, Hashable {
    var id: String { path }
    let name: String
    /// Relative to the share, e.g. "Movies/Trip" (share name is the first component).
    let path: String
    let isDirectory: Bool
    let sizeBytes: Int64
    let lastModified: Date

    static let videoExtensions: Set<String> = [
        "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v", "ts", "m2ts", "mpg", "mpeg", "3gp",
    ]

    var isVideo: Bool {
        !isDirectory && Self.videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }
}

/// A saved login for one SMB server. The password is kept in the Keychain, not here.
struct SmbServerProfile: Identifiable, Codable, Hashable {
    var id: String { host }
    let host: String
    var username: String = ""
    var domain: String = ""
}
