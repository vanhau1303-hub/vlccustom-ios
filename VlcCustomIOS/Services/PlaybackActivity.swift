import Foundation

/// Set while a video is actively open in `PlayerScreen`. SwiftUI keeps a list screen's `.task` work running even
/// while it's covered by a `fullScreenCover`, so without this flag, list rows still visible underneath the player
/// keep firing thumbnail fetches through the same SMB connection/loopback proxy the player is streaming from —
/// this was the actual cause of "video takes a long time to start playing" once thumbnails were added everywhere.
final class PlaybackActivity: ObservableObject {
    static let shared = PlaybackActivity()
    @Published var isBusy = false
    private init() {}
}
