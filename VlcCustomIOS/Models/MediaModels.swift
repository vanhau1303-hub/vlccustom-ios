import Foundation

/// A song found locally (inside the picked folder) or on an SMB share.
struct AudioItem: Identifiable, Hashable {
    var id: String { source }
    let name: String
    let title: String
    let artist: String
    let album: String
    let source: String
    let sizeBytes: Int64
    let lastModified: Date

    var isSmb: Bool { source.hasPrefix("smb://") }
}

/// A picture found locally or on an SMB share.
struct ImageItem: Identifiable, Hashable {
    var id: String { source }
    let name: String
    let source: String
    let sizeBytes: Int64
    let lastModified: Date

    var isSmb: Bool { source.hasPrefix("smb://") }
}

/// One entry of a playlist: a URI (content/file/smb) and a display title.
struct PlaylistItem: Identifiable, Codable, Hashable {
    var id: String { uri }
    let uri: String
    let title: String
}

/// A named, ordered list of `PlaylistItem`s (used for both video and music playlists — same shape, kept in separate
/// stores so they show up in the right tab).
struct Playlist: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var items: [PlaylistItem]
}

enum FavoriteKind: String, Codable {
    case local, smb
}

/// A folder the user starred for quick access, on the device or on an SMB share.
struct FavoriteFolder: Identifiable, Codable, Hashable {
    var id: String { "\(kind.rawValue)|\(host)|\(path)" }
    let kind: FavoriteKind
    var host: String = ""
    let path: String
    let title: String
}

extension SmbEntry {
    private static let audioExtensions: Set<String> = [
        "mp3", "flac", "wav", "aac", "m4a", "m4b", "ogg", "oga", "opus", "wma", "ape", "alac", "aiff", "aif", "mka",
    ]
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif", "tif", "tiff",
    ]

    var isAudio: Bool { !isDirectory && Self.audioExtensions.contains((name as NSString).pathExtension.lowercased()) }
    var isImage: Bool { !isDirectory && Self.imageExtensions.contains((name as NSString).pathExtension.lowercased()) }
}
