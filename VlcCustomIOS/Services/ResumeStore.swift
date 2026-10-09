import Combine
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

/// Where each video was left off, how long it is, and whether it was watched to the end — for "Xem tiếp", the
/// progress bar and "Đã xem" mark on thumbnails, and Cài đặt → Đang xem dở. Kept in memory (cells read it on every
/// redraw) and saved to UserDefaults on change; main thread only. The last 800 videos are kept.
final class WatchHistory: ObservableObject {
    static let shared = WatchHistory()
    private static let key = "video_positions"
    private static let limit = 800

    struct Entry: Codable {
        var ms: Int32
        var at: Date
        /// Missing in entries saved before v0.65.
        var durationMs: Int32?
        var watched: Bool?
    }

    struct InProgress: Identifiable {
        let source: String
        let ms: Int32
        let durationMs: Int32?
        let at: Date
        var id: String { source }
        var name: String { (source as NSString).lastPathComponent }
        var fraction: Double? {
            guard let durationMs, durationMs > 0 else { return nil }
            return min(1, max(0, Double(ms) / Double(durationMs)))
        }
    }

    @Published private(set) var entries: [String: Entry]

    private init() {
        entries = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    /// Where to pick `source` up again: nil when it was barely started or watched to the end.
    func position(for source: String) -> Int32? {
        guard let entry = entries[source], entry.ms >= 30_000 else { return nil }
        return entry.ms
    }

    /// For the thumbnail: how far it was watched (nil = not started / unknown length) and whether it was finished.
    func progress(for source: String) -> (fraction: Double?, watched: Bool) {
        guard let entry = entries[source] else { return (nil, false) }
        var fraction: Double?
        if entry.ms >= 30_000, let duration = entry.durationMs, duration > 0 {
            fraction = min(1, Double(entry.ms) / Double(duration))
        }
        return (fraction, entry.watched == true)
    }

    /// Videos left part-way, the latest first.
    var inProgress: [InProgress] {
        entries.compactMap { source, entry in
            entry.ms >= 30_000 ? InProgress(source: source, ms: entry.ms, durationMs: entry.durationMs, at: entry.at) : nil
        }
        .sorted { $0.at > $1.at }
    }

    /// Remembers `ms`. The last minute counts as watched to the end; the first 30 s as not started.
    func save(source: String, ms: Int32, durationMs: Int32) {
        var entry = entries[source] ?? Entry(ms: 0, at: Date())
        if durationMs > 0 { entry.durationMs = durationMs }
        if durationMs > 120_000, ms > durationMs - 60_000 {
            entry.watched = true
            entry.ms = 0
        } else if ms < 30_000 {
            // Barely started: nothing to resume (a video watched before keeps its mark).
            guard entries[source] != nil else { return }
            if entry.watched != true, entry.ms < 30_000 { return }
            entry.ms = 0
        } else {
            entry.ms = ms
        }
        entry.at = Date()
        set(source, entry)
    }

    /// Played to the end.
    func markWatched(_ source: String, durationMs: Int32) {
        var entry = entries[source] ?? Entry(ms: 0, at: Date())
        entry.ms = 0
        entry.watched = true
        if durationMs > 0 { entry.durationMs = durationMs }
        entry.at = Date()
        set(source, entry)
    }

    /// Forgets the position (Đang xem dở → Xoá), keeping a "watched" mark.
    func clearPosition(_ source: String) {
        guard var entry = entries[source] else { return }
        if entry.watched == true {
            entry.ms = 0
            set(source, entry)
        } else {
            entries[source] = nil
            persist()
        }
    }

    private func set(_ source: String, _ entry: Entry) {
        entries[source] = entry
        if entries.count > Self.limit {
            for (old, _) in entries.sorted(by: { $0.value.at < $1.value.at }).prefix(entries.count - Self.limit) {
                entries[old] = nil
            }
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// The player's view of `WatchHistory`.
enum PositionStore {
    static func save(source: String, ms: Int32, durationMs: Int32) {
        WatchHistory.shared.save(source: source, ms: ms, durationMs: durationMs)
    }

    static func position(for source: String) -> Int32? { WatchHistory.shared.position(for: source) }

    static func markWatched(_ source: String, durationMs: Int32) {
        WatchHistory.shared.markWatched(source, durationMs: durationMs)
    }
}
