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
