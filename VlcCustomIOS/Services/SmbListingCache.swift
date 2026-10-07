import Foundation
import CryptoKit

/// The last listing of every SMB folder opened, in memory and on disk: going into a folder (or back to one, or
/// reopening the app) shows its files at once while the fresh listing is read over SMB in the background.
enum SmbListingCache {
    private final class Box { let entries: [SmbEntry]; init(_ entries: [SmbEntry]) { self.entries = entries } }
    private static let memory: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 100
        return cache
    }()
    private static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("smb_listings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func key(_ host: String, _ path: String) -> String {
        SHA256.hash(data: Data("\(host.lowercased())|\(path)".utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func get(host: String, path: String) async -> [SmbEntry]? {
        let key = key(host, path)
        if let box = memory.object(forKey: key as NSString) { return box.entries }
        let file = directory.appendingPathComponent(key + ".json")
        return await Task.detached(priority: .userInitiated) { () -> [SmbEntry]? in
            guard let data = try? Data(contentsOf: file),
                  let entries = try? JSONDecoder().decode([SmbEntry].self, from: data) else { return nil }
            memory.setObject(Box(entries), forKey: key as NSString)
            return entries
        }.value
    }

    static func put(host: String, path: String, entries: [SmbEntry]) {
        let key = key(host, path)
        memory.setObject(Box(entries), forKey: key as NSString)
        let file = directory.appendingPathComponent(key + ".json")
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
        }
    }
}
