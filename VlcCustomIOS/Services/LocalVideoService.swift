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

    /// Video files under `folder` (recursive). Call within the folder's security scope.
    static func scan(_ folder: URL) -> [VideoItem] {
        var result: [VideoItem] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return result
        }
        for case let fileUrl as URL in enumerator {
            guard let values = try? fileUrl.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true { continue }
            guard videoExtensions.contains(fileUrl.pathExtension.lowercased()) else { continue }
            result.append(VideoItem(
                name: fileUrl.lastPathComponent,
                source: fileUrl.absoluteString,
                sizeBytes: Int64(values.fileSize ?? 0),
                lastModified: values.contentModificationDate ?? .distantPast
            ))
        }
        return result.sorted { $0.lastModified > $1.lastModified }
    }
}
