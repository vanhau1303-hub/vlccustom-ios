import Foundation

/// iOS apps cannot browse the whole file system like Android/Windows can; the user picks a folder once (through the
/// Files app picker) and grants a "security-scoped bookmark", which is saved so the app can reopen the same folder on
/// later launches without asking again.
enum LocalVideoService {
    private static let bookmarkKey = "local_folder_bookmark"

    private static let videoExtensions: Set<String> = [
        "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v", "ts", "m2ts", "mpg", "mpeg", "3gp",
    ]

    static func saveBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(options: .minimalBookmark) else { return }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    /// The folder picked last time, still access-scoped; call `url.stopAccessingSecurityScopedResource()` when done with it.
    static func restoredFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        return url
    }

    private static let audioExtensions: Set<String> = [
        "mp3", "flac", "wav", "aac", "m4a", "m4b", "ogg", "oga", "opus", "wma", "ape", "alac", "aiff", "aif", "mka",
        "vob", "dsf", "dff", "ac3", "dts", "mpc", "wv", "tta", "tak", "amr", "caf", "m4r", "mp2", "mpa", "spx", "au",
    ]
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif", "tif", "tiff",
    ]

    /// Video files under `folder` (recursive). Call within the folder's security scope.
    static func scan(_ folder: URL) -> [VideoItem] {
        scanFiles(folder, matching: videoExtensions).map {
            VideoItem(name: $0.name, source: $0.url.absoluteString, sizeBytes: $0.size, lastModified: $0.modified)
        }
    }

    /// Audio files under `folder` (recursive). Call within the folder's security scope.
    static func scanAudio(_ folder: URL) -> [AudioItem] {
        scanFiles(folder, matching: audioExtensions).map {
            AudioItem(name: $0.name, title: $0.url.deletingPathExtension().lastPathComponent, artist: "", album: "",
                      source: $0.url.absoluteString, sizeBytes: $0.size, lastModified: $0.modified)
        }
    }

    /// Picture files under `folder` (recursive). Call within the folder's security scope.
    static func scanImages(_ folder: URL) -> [ImageItem] {
        scanFiles(folder, matching: imageExtensions).map {
            ImageItem(name: $0.name, source: $0.url.absoluteString, sizeBytes: $0.size, lastModified: $0.modified)
        }
    }

    private struct FoundFile { let url: URL; let name: String; let size: Int64; let modified: Date }

    private static func scanFiles(_ folder: URL, matching extensions: Set<String>) -> [FoundFile] {
        var result: [FoundFile] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return result
        }
        for case let fileUrl as URL in enumerator {
            guard let values = try? fileUrl.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true { continue }
            guard extensions.contains(fileUrl.pathExtension.lowercased()) else { continue }
            result.append(FoundFile(
                url: fileUrl,
                name: fileUrl.lastPathComponent,
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast
            ))
        }
        return result.sorted { $0.modified > $1.modified }
    }
}
