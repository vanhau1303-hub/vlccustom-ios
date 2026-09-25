import Foundation

/// Set while a video is actively open in `PlayerScreen`. SwiftUI keeps a list screen's `.task` work running even
/// while it's covered by a `fullScreenCover`, so without this flag, list rows still visible underneath the player
/// keep firing thumbnail fetches through the same SMB connection/loopback proxy the player is streaming from —
/// this was the actual cause of "video takes a long time to start playing" once thumbnails were added everywhere.
final class PlaybackActivity: ObservableObject {
    static let shared = PlaybackActivity()
    @Published var isBusy = false {
        didSet {
            guard isBusy != oldValue else { return }
            ThumbnailPolicy.shared.videoOpen = isBusy
            if isBusy {
                // The video gets the network to itself: stop frame grabs and proxy streams feeding thumbnails.
                VLCSnapshotter.cancelAll()
                SmbHttpProxy.shared.cancelBackground()
            }
            Task { await ThumbnailService.shared.policyChanged() }
        }
    }
    private init() {}
}

/// How hard thumbnail generation may push the SMB server right now.
/// "Ưu tiên tạo thumbnail nhanh" (on by default): three at a time, and a folder's thumbnails are all made ahead of
/// the scroll. The moment a video opens it drops back to the normal, gentle mode (and new SMB thumbnail work waits)
/// so playback is not competing with it; closing the video brings the fast mode back.
final class ThumbnailPolicy: @unchecked Sendable {
    static let shared = ThumbnailPolicy()
    static let fastKey = "thumbs_fast"

    private let lock = NSLock()
    private var _fastEnabled: Bool
    private var _videoOpen = false

    private init() {
        _fastEnabled = UserDefaults.standard.object(forKey: Self.fastKey) as? Bool ?? true
    }

    var fastEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _fastEnabled }
        set { lock.lock(); _fastEnabled = newValue; lock.unlock() }
    }

    var videoOpen: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _videoOpen }
        set { lock.lock(); _videoOpen = newValue; lock.unlock() }
    }

    /// Fast mode in effect right now (enabled, and no video open).
    var isFast: Bool { fastEnabled && !videoOpen }

    /// Concurrent SMB thumbnail jobs allowed right now.
    var jobLimit: Int { isFast ? 3 : 1 }
}
