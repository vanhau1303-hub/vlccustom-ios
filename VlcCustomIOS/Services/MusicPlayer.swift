import Foundation
import MobileVLCKit
import MediaPlayer
import UIKit
import AVFoundation

/// The list of songs currently being played and where we are in it — the music equivalent of `PlaybackQueue`,
/// kept separate so playing a song never disturbs an in-progress video queue (and vice versa).
final class MusicQueue: ObservableObject {
    static let shared = MusicQueue()

    enum RepeatMode { case off, one, all }

    @Published private(set) var items: [AudioItem] = []
    @Published private(set) var index: Int = 0
    @Published var shuffle = false
    @Published var repeatMode: RepeatMode = .off
    private(set) var label: String = ""

    var current: AudioItem? { items.indices.contains(index) ? items[index] : nil }
    var hasNext: Bool { repeatMode != .off || index < items.count - 1 }
    var hasPrevious: Bool { index > 0 }

    func start(_ items: [AudioItem], index: Int, label: String = "") {
        self.items = items
        self.index = index
        self.label = label
    }

    @discardableResult
    func moveNext() -> AudioItem? {
        guard !items.isEmpty else { return nil }
        if repeatMode == .one { return current }
        if shuffle, items.count > 1 {
            index = Int.random(in: 0..<items.count)
            return current
        }
        if index < items.count - 1 {
            index += 1
            return current
        }
        if repeatMode == .all {
            index = 0
            return current
        }
        return nil
    }

    @discardableResult
    func movePrevious() -> AudioItem? {
        guard hasPrevious else { return nil }
        index -= 1
        return current
    }
}

/// A dedicated `VLCMediaPlayer` for audio, separate from the video player, configured for background playback and
/// lock-screen / Control Center controls (the iOS equivalent of Android's `MediaSession` + notification).
final class MusicPlayer: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    static let shared = MusicPlayer()

    let mediaPlayer = VLCMediaPlayer()
    @Published var isPlaying = false
    @Published var time: Int32 = 0
    @Published var duration: Int32 = 0
    @Published var didReachEnd = false
    @Published var showError = false
    /// Cover art of the current song (embedded in the file, extracted by libVLC), nil until found / if none.
    @Published var artwork: UIImage?

    var progress: Double { duration > 0 ? Double(time) / Double(duration) : 0 }

    private override init() {
        super.init()
        mediaPlayer.delegate = self
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        configureRemoteCommands()
    }

    private var smbRoute: SmbPlaybackRoute = .direct
    private var playGeneration = 0

    /// Same routing as the video player: SMB goes straight through libVLC's SMB2 module first, then the proxy.
    func playCurrent() {
        guard let item = MusicQueue.shared.current else { return }
        didReachEnd = false
        smbRoute = .direct
        start(item)
    }

    private func start(_ item: AudioItem) {
        playGeneration += 1
        let generation = playGeneration
        artwork = nil
        Task { @MainActor in
            let cover = await ThumbnailService.shared.audioCover(source: item.source)
            guard generation == self.playGeneration else { return }
            self.artwork = cover
            self.updateNowPlaying()
        }
        guard let (host, path) = SmbUri.parse(item.source) else {
            guard let local = URL(string: item.source) else { return }
            let media = VLCMedia(url: local)
            media.addOption(":no-video")
            mediaPlayer.media = media
            mediaPlayer.play()
            updateNowPlaying()
            return
        }
        let route = smbRoute
        Task { @MainActor in
            let login = await SmbRegistry.shared.login(for: host)
            guard generation == self.playGeneration else { return }
            guard let media = SmbPlayback.media(host: host, path: path, route: route, login: login) else {
                self.showError = true
                return
            }
            // Audio only, even for a .vob/.mkv with a picture track: there is no video surface here.
            media.addOption(":no-video")
            self.mediaPlayer.media = media
            self.mediaPlayer.play()
            self.updateNowPlaying()
        }
    }

    func togglePlayPause() {
        if mediaPlayer.isPlaying { mediaPlayer.pause() } else { mediaPlayer.play() }
        updateNowPlaying()
    }

    func skip(ms: Int32) {
        let target = max(0, mediaPlayer.time.intValue + ms)
        mediaPlayer.time = VLCTime(int: duration > 0 ? min(target, duration - 500) : target)
    }

    func seek(to fraction: Double) {
        mediaPlayer.position = Float(fraction)
    }

    func stop() {
        playGeneration += 1
        artwork = nil
        MusicUI.shared.collapse()
        mediaPlayer.stop()
        MusicQueue.shared.start([], index: 0)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func playNext() {
        if MusicQueue.shared.moveNext() != nil { playCurrent() } else { mediaPlayer.stop() }
    }

    func playPrevious() {
        if MusicQueue.shared.movePrevious() != nil { playCurrent() }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.mediaPlayer.play(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.mediaPlayer.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.playNext(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.playPrevious(); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent, self.duration > 0 else { return .commandFailed }
            self.mediaPlayer.time = VLCTime(int: Int32(event.positionTime * 1000))
            return .success
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = MusicQueue.shared.current?.title ?? ""
        info[MPMediaItemPropertyArtist] = MusicQueue.shared.current?.artist ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = Double(duration) / 1000
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(time) / 1000
        info[MPNowPlayingInfoPropertyPlaybackRate] = mediaPlayer.isPlaying ? 1.0 : 0.0
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ notification: Notification) {
        DispatchQueue.main.async {
            self.isPlaying = self.mediaPlayer.isPlaying
            if self.isPlaying { MusicUI.shared.showMiniBar() }
            switch self.mediaPlayer.state {
            case .ended:
                self.didReachEnd = true
                self.playNext()
            case .error:
                if self.smbRoute == .direct, let item = MusicQueue.shared.current, item.isSmb {
                    PlaybackDiagnostics.append("music: direct failed, retrying through proxy")
                    self.smbRoute = .proxy
                    self.start(item)
                } else {
                    self.showError = true
                }
            default: break
            }
            self.updateNowPlaying()
        }
    }

    func mediaPlayerTimeChanged(_ notification: Notification) {
        DispatchQueue.main.async {
            self.time = self.mediaPlayer.time.intValue
            self.duration = self.mediaPlayer.media?.length.intValue ?? 0
            self.updateNowPlaying()
        }
    }
}
