import Foundation
import MobileVLCKit

/// Keeps libVLC's blocking calls off the main thread. From a real freeze log (switching videos over SMB while the
/// previous one was still reading): the UI locked up until the app was killed.
///
/// - `VLCMediaPlayer.stop()` is asynchronous in this VLCKit, but players were released right after it — and
///   releasing a player that has not finished stopping makes libVLC stop it *synchronously on the main thread*,
///   waiting for the SMB read in flight. `retire` keeps the player alive until libVLC reports it stopped.
/// - `play()` and `isPlaying` are synchronous and take libVLC's player locks, which are held while an input is
///   being torn down. `play` now runs on a background serial queue, and `isActive` reads VLCKit's cached,
///   event-driven state instead.
enum VLCControl {
    private static let queue = DispatchQueue(label: "vlc-control", qos: .userInitiated)
    private static var retired: [VLCMediaPlayer] = []
    private static let releaseQueue = DispatchQueue(label: "vlc-release", qos: .utility)

    /// Sets `media` (if given) and starts playback, off the main thread, in call order.
    static func play(_ player: VLCMediaPlayer, media: VLCMedia? = nil) {
        queue.async {
            if let media { player.media = media }
            player.play()
        }
    }

    /// Any other libVLC call that may wait on the player's locks (seeking...), in call order, off the main thread.
    static func run(_ block: @escaping () -> Void) {
        queue.async(execute: block)
    }

    /// Stop, queued behind any pending play/seek so it can never be overtaken by them.
    static func stop(_ player: VLCMediaPlayer) {
        queue.async { player.stop() }
    }

    static func pause(_ player: VLCMediaPlayer) {
        queue.async { player.pause() }
    }

    /// Play/pause from cached state (never blocks).
    static func toggle(_ player: VLCMediaPlayer) {
        if player.isActive { pause(player) } else { play(player) }
    }

    /// Stops `player` and holds on to it until libVLC has really stopped, so it is never released mid-stop.
    static func retire(_ player: VLCMediaPlayer) {
        DispatchQueue.main.async { player.delegate = nil }
        // Queued behind any play still pending for it (opened then closed quickly), so that play cannot start the
        // retired player again; only then is it parked until libVLC reports it stopped.
        queue.async {
            player.stop()
            DispatchQueue.main.async {
                retired.append(player)
                sweepSoon()
            }
        }
    }

    private static func sweepSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // A player that never reports stopping is kept (a small leak) rather than risking a frozen UI.
            let finished = retired.filter { $0.isFinished }
            retired.removeAll { $0.isFinished }
            if !retired.isEmpty { sweepSoon() }
            // The last reference is dropped on a background thread, never the main one. Releasing a libVLC player
            // destroys the video output it keeps for reuse, and the iOS video output does its teardown with a
            // synchronous hop to the main thread — from the main thread that is a deadlock (a real freeze log: the
            // previous video's player was released right as the next file opened, and the UI never came back).
            if !finished.isEmpty {
                releaseQueue.async { withExtendedLifetime(finished) {} }
            }
        }
    }
}

extension VLCMediaPlayer {
    /// Playing, or on its way to (opening/buffering) — from VLCKit's cached state, no libVLC lock involved.
    var isActive: Bool {
        switch state {
        case .playing, .buffering, .opening, .esAdded: return true
        default: return false
        }
    }

    /// Nothing left running inside libVLC for this player.
    var isFinished: Bool {
        switch state {
        case .stopped, .ended, .error: return true
        default: return false
        }
    }
}
