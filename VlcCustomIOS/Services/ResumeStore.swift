import Foundation
import UIKit

/// Where the user was, so a relaunch after iOS killed the app in the background (it reclaims memory from suspended
/// apps — a video app is an easy target) lands back in the same place instead of the start screen:
/// the tab, the SMB server + folder open in Mạng, and the video being watched with its position.
enum ResumeStore {
    private static let tabKey = "resume_tab"
    private static let hostKey = "resume_smb_host"
    private static let pathKey = "resume_smb_path"
    private static let videoKey = "resume_video"

    struct Video: Codable {
        let source: String
        let timeMs: Int32
        let savedAt: Date
    }

    static var tab: Int? {
        get { UserDefaults.standard.object(forKey: tabKey) as? Int }
        set { UserDefaults.standard.set(newValue, forKey: tabKey) }
    }

    static func saveFolder(host: String?, path: String) {
        if let host {
            UserDefaults.standard.set(host, forKey: hostKey)
            UserDefaults.standard.set(path, forKey: pathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: hostKey)
            UserDefaults.standard.removeObject(forKey: pathKey)
        }
    }

    static var folder: (host: String, path: String)? {
        guard let host = UserDefaults.standard.string(forKey: hostKey), !host.isEmpty else { return nil }
        return (host, UserDefaults.standard.string(forKey: pathKey) ?? "")
    }

    static func saveVideo(source: String, timeMs: Int32) {
        let video = Video(source: source, timeMs: timeMs, savedAt: Date())
        if let data = try? JSONEncoder().encode(video) { UserDefaults.standard.set(data, forKey: videoKey) }
    }

    static func clearVideo() {
        UserDefaults.standard.removeObject(forKey: videoKey)
    }

    /// The video that was open when the app went away (only if recent: 12 hours).
    static var video: Video? {
        guard let data = UserDefaults.standard.data(forKey: videoKey),
              let video = try? JSONDecoder().decode(Video.self, from: data),
              Date().timeIntervalSince(video.savedAt) < 12 * 3600 else { return nil }
        return video
    }
}

/// Where each video was left off — "Xem tiếp từ 12:34?" when it is opened again. Kept for the last 300 videos;
/// forgotten once a video is watched to (nearly) the end.
enum PositionStore {
    private static let key = "video_positions"
    private static let limit = 300

    private struct Entry: Codable {
        let ms: Int32
        let at: Date
    }

    private static var all: [String: Entry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
            return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
        }
        set {
            var entries = newValue
            if entries.count > limit {
                for (source, _) in entries.sorted(by: { $0.value.at < $1.value.at }).prefix(entries.count - limit) {
                    entries[source] = nil
                }
            }
            if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: key) }
        }
    }

    /// Remembers `ms` unless it is the very start or the last minute (then the video counts as watched).
    static func save(source: String, ms: Int32, durationMs: Int32) {
        var entries = all
        if ms < 30_000 || (durationMs > 0 && ms > durationMs - 60_000) {
            guard entries[source] != nil else { return }
            entries[source] = nil
        } else {
            entries[source] = Entry(ms: ms, at: Date())
        }
        all = entries
    }

    static func position(for source: String) -> Int32? { all[source]?.ms }

    static func clear(_ source: String) {
        var entries = all
        guard entries[source] != nil else { return }
        entries[source] = nil
        all = entries
    }
}
