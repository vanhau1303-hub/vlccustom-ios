import Combine
import MediaPlayer
import SwiftUI
import MobileVLCKit
import UIKit

enum PlayerDragMode: Equatable { case seek, brightness, volume, edgeBack }

/// Full-screen player for the current item of `PlaybackQueue`: local files are opened directly, SMB files through
/// `SmbHttpProxy` (so it does not matter whether VLCKit's own build has SMB2/3 support).
struct PlayerScreen: View {
    let onClose: () -> Void
    @StateObject private var queue = PlaybackQueue.shared
    @StateObject private var player = VlcPlayerController()
    /// Seek-bar scrubbing, observed only by the time row (scrubbing used to redraw the whole player per movement).
    @State private var scrub = ScrubState()
    /// Gesture bookkeeping the screen never draws (see `GestureScratch`).
    @State private var scratch = GestureScratch()
    /// The "+12s" / "Âm lượng 40%" bubble, observed only by its own small view.
    @State private var hint = GestureHint()
    @State private var showControls = true
    /// The subtitle sheet, open on this tab (captions button: the file's tracks; AI button: AI).
    @State private var subtitleSheet: SubtitleSheet.Tab?
    @State private var showPictureControls = false
    /// The video's thumbnail, blurred behind "Đang mở…" so opening never shows a bare black screen.
    @State private var poster: UIImage?
    /// Touch lock: gestures and controls off; the lock badge (shown on a tap) unlocks when held.
    @State private var locked = false
    @State private var showUnlock = false
    /// Not observed here: the subtitle overlay and status badge observe it themselves, so a new cue or status does
    /// not re-render the whole player (video surface, gesture layer, controls).
    private let live = LiveSubtitles.shared

    // Gesture state — mirrors the Android player: horizontal drag seeks, vertical drag on the left half adjusts
    // screen brightness and on the right half adjusts VLC's own volume, double-tap on either side skips ±30s and
    // double-tap in the middle toggles play/pause.
    @State private var showQueue = false
    /// AI subtitles were on for the previous episode: they start on their own for this one once its length is known.
    @State private var continueSubtitles = false

    private static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        GeometryReader { geo in
        ZStack {
            Color.black.ignoresSafeArea()
            VlcVideoView(player: player).ignoresSafeArea()
                .allowsHitTesting(false)

            if player.isLoading, let poster {
                Image(uiImage: poster).resizable().scaledToFit()
                    .blur(radius: 14)
                    .opacity(0.55)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if locked {
                lockLayer
            } else {
                // Gestures live on a transparent layer above the video, not on the video view itself: once playback
                // starts, libVLC inserts its own vout view (with its own tap recognizer) inside the drawable, which
                // swallowed every tap — so the controls could be hidden but never shown again.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .gesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { value in handleDoubleTap(at: value.location, size: geo.size) }
                            .exclusively(before: SpatialTapGesture(count: 1).onEnded { _ in
                                withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                                if showControls { keepControlsVisible() }
                            })
                    )
                    .simultaneousGesture(playerDragGesture(in: geo.size))
                    // Press and hold = 2× speed while held (VLC for iOS's "long touch speed-up").
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.45)
                            .sequenced(before: DragGesture(minimumDistance: 0))
                            .onChanged { value in
                                if case .second(true, _) = value, scratch.speedBoostFrom == nil, scratch.dragMode == nil {
                                    scratch.speedBoostFrom = player.playbackRate
                                    player.playbackRate = 2.0
                                    hint.set("2× ▶▶")
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                            }
                            .onEnded { _ in endSpeedBoost() }
                    )
            }

            if player.isLoading {
                VStack(spacing: 10) {
                    ProgressView().tint(.white).scaleEffect(1.4)
                    Text("Đang mở…").font(.footnote).foregroundStyle(.white.opacity(0.85))
                }
                .allowsHitTesting(false)
            }

            GestureHintView(hint: hint)

            LiveCueOverlay(clock: player.clock, live: live)
                .padding(.bottom, showControls ? 230 : 28)
                .allowsHitTesting(false)

            LiveStatusBadge(live: live)

            if let offer = player.resumeOffer {
                ResumeBanner(timeText: format(offer)) {
                    player.acceptResume()
                } onDismiss: {
                    player.resumeOffer = nil
                }
                .padding(.bottom, showControls ? 240 : 40)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .transition(.opacity)
                .task(id: offer) {
                    // Offered for 8 seconds, then playback simply goes on from the start.
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    if player.resumeOffer == offer { withAnimation { player.resumeOffer = nil } }
                }
            }

            if let from = player.resumedFrom {
                StartOverBanner(timeText: format(from)) {
                    withAnimation { player.startOver() }
                }
                .padding(.bottom, showControls ? 240 : 40)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .transition(.opacity)
                .task(id: from) {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    if player.resumedFrom == from { withAnimation { player.resumedFrom = nil } }
                }
            }

            if showControls && !locked {
                VStack(spacing: 0) {
                    // Top bar: close, file name, touch lock. All other tools sit in the bottom panel as roomy 44pt
                    // round buttons, the rarer ones (aspect, deinterlace, picture) tucked into a "more" menu.
                    HStack(spacing: 10) {
                        controlButton("xmark") { close() }
                        Text(queue.current?.name ?? "")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.white).lineLimit(2)
                        Spacer(minLength: 0)
                        // Touch lock (the bottom row is full on an upright phone).
                        controlButton("lock.open.fill") { lock() }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))

                    Spacer()

                    VStack(spacing: 14) {
                        HStack(spacing: 10) {
                            PlayerTimeRow(clock: player.clock, live: live, scrub: scrub,
                                    onScrub: { [scrub] fraction in
                                        scrub.follow(fraction)
                                        // The picture follows the thumb too.
                                        if player.duration > 0 { player.scrub(toMs: Int32(fraction * Double(player.duration))) }
                                        keepControlsVisible()
                                    },
                                    onCommit: { [scrub] fraction in
                                        if player.duration > 0 {
                                            player.endScrub(atMs: Int32(fraction * Double(player.duration)))
                                        } else {
                                            player.seek(to: fraction)
                                        }
                                        keepControlsVisible()
                                        // Hold the new position until VLC reports it, instead of snapping back.
                                        scrub.release(at: fraction)
                                    })
                        }
                        HStack(spacing: 36) {
                            transportButton("backward.end.fill", size: 22) { queue.movePrevious(); player.playCurrent() }
                                .disabled(!queue.hasPrevious).opacity(queue.hasPrevious ? 1 : 0.35)
                            transportButton("gobackward.10", size: 26) { player.skip(ms: -10_000) }
                            transportButton(player.isPlaying ? "pause.circle.fill" : "play.circle.fill", size: 54) { player.togglePlayPause() }
                            transportButton("goforward.10", size: 26) { player.skip(ms: 10_000) }
                            transportButton("forward.end.fill", size: 22) { playNextOrClose() }
                                .disabled(!queue.hasNext).opacity(queue.hasNext ? 1 : 0.35)
                        }
                        // Tools row, under the transport controls (the top bar only carries close + the file name).
                        HStack(spacing: 14) {
                            Button { cycleSpeed(); keepControlsVisible() } label: {
                                Text(speedLabel).font(.subheadline.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(Color.black.opacity(0.35)))
                            }
                            controlButton("rotate.right") { toggleOrientation(landscapeNow: geo.size.width > geo.size.height) }
                            if queue.items.count > 1 {
                                controlButton("list.bullet") { showQueue = true }
                            }
                            controlButton("captions.bubble") { subtitleSheet = .tracks }
                            controlButton("waveform") { subtitleSheet = .ai }
                            Menu {
                                Button { player.cycleAspectRatio() } label: { Label("Tỉ lệ khung hình", systemImage: "aspectratio") }
                                Button { player.toggleDeinterlace() } label: {
                                    Label(player.deinterlaceOn ? "Tắt khử sọc" : "Bật khử sọc", systemImage: "tv")
                                }
                                Button { showPictureControls = true } label: { Label("Chỉnh màu", systemImage: "slider.horizontal.3") }
                                if queue.current?.isSmb == true {
                                    Button { player.switchRoute() } label: {
                                        Label(player.isCompatibilityRoute ? "Phát bằng chế độ thường" : "Phát bằng chế độ tương thích",
                                              systemImage: "arrow.triangle.2.circlepath")
                                    }
                                }
                            } label: {
                                controlIcon("ellipsis")
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                    .padding(.bottom, 12)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden()
        .tint(AppTheme.shared.accent)
        .fadeInOnAppear()
        .onAppear {
            MusicUI.shared.videoOpened()
            player.playCurrent(); PlaybackActivity.shared.isBusy = true; keepControlsVisible()
            // AI subtitles follow the playhead (seeks included).
            live.playheadProvider = { [weak player] in Int(player?.time ?? 0) }
        }
        .onDisappear {
            player.stop(); live.reset(); PlaybackActivity.shared.isBusy = false
            LiveSubtitles.nextEpisode.reset()
            Task { await WhisperEngine.shared.unloadAll() }
            OrientationLock.unlock()
        }
        .onChange(of: player.didReachEnd) { reached in if reached { playNextOrClose() } }
        // Another file in the same player (next in the folder, picked from the list): drop the previous one's
        // AI / translated subtitles.
        .task(id: queue.current?.source) {
            poster = nil
            guard let source = queue.current?.source else { return }
            poster = await ThumbnailService.shared.cachedThumbnail(source: source)
        }
        .onChange(of: queue.current?.source) { source in
            // Subtitle timing is per video.
            live.delayMs = 0
            let wasSpeech = live.mode == .speech && live.source != nil && live.source != source
            // The next episode's background job stops here; what it made is on disk and picked up below.
            LiveSubtitles.nextEpisode.reset()
            live.reset(unlessFor: source)
            if wasSpeech { continueSubtitles = true }
        }
        .onReceive(player.clock.$duration) { duration in
            guard continueSubtitles, duration > 0, let source = queue.current?.source else { return }
            continueSubtitles = false
            startSpeech(on: live, source: source, durationMs: Int(duration))
        }
        // This episode's subtitles are complete: make the next episode's in the background.
        .onReceive(live.$running.dropFirst()) { running in
            guard !running, live.isComplete, LiveSubtitles.nextEpisode.source == nil,
                  let next = queue.next, let (host, path) = SmbUri.parse(next.source) else { return }
            Task {
                guard let length = await MediaHeaderDuration.lengthMs(host: host, path: path),
                      queue.next?.source == next.source, !LiveSubtitles.nextEpisode.running else { return }
                PlaybackDiagnostics.append("asr: next episode in the background — \(next.name)")
                startSpeech(on: LiveSubtitles.nextEpisode, source: next.source, durationMs: Int(length))
            }
        }
        .alert("Không phát được video", isPresented: $player.showError) {
            Button("Đóng", role: .cancel) {}
        } message: {
            Text("Đã thử cả chế độ thường và chế độ tương thích. Nhấn giữ file → Kiểm tra file để xem định dạng bên trong.")
        }
        .sheet(isPresented: $showQueue) {
            PlayQueueSheet(queue: queue) { index in
                showQueue = false
                queue.jump(to: index)
                player.playCurrent()
            }
        }
        .sheet(item: $subtitleSheet) { tab in
            SubtitleSheet(player: player, live: live, tab: tab, videoName: queue.current?.name ?? "",
                          source: queue.current?.source ?? "")
        }
        .sheet(isPresented: $showPictureControls) {
            PictureControlsSheet(player: player)
        }
        }
    }

    // MARK: - Controls

    private func controlIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Circle().fill(Color.black.opacity(0.35)))
            .contentShape(Circle())
    }

    private func controlButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button { action(); keepControlsVisible() } label: { controlIcon(systemName) }
    }

    private func transportButton(_ systemName: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button { action(); keepControlsVisible() } label: {
            Image(systemName: systemName)
                .font(.system(size: size))
                .foregroundStyle(.white)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
    }

    /// Shows the controls and hides them again after 4s of no interaction while playing.
    /// Pushes the auto-hide of the controls 4 s further. One timer at a time (this runs on every scrub movement:
    /// it used to bump a @State counter — a full redraw — and start a new task each time).
    private func keepControlsVisible() {
        scratch.hideAt = Date().addingTimeInterval(4)
        guard !scratch.hideTimerRunning else { return }
        scratch.hideTimerRunning = true
        Task { @MainActor in
            while scratch.hideAt > Date() {
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, scratch.hideAt.timeIntervalSinceNow) * 1_000_000_000))
            }
            scratch.hideTimerRunning = false
            if player.isPlaying, !scrub.seeking, subtitleSheet == nil, !showPictureControls, !showQueue {
                withAnimation(.easeInOut(duration: 0.25)) { showControls = false }
            }
        }
    }

    /// The rotate button: locks to landscape when currently upright, back to portrait otherwise. The lock is lifted
    /// again when the player closes.
    private func toggleOrientation(landscapeNow: Bool) {
        OrientationLock.lock(landscapeNow ? .portrait : .landscapeRight)
    }

    private var speedLabel: String { "\(player.playbackRate == 1 ? "1" : String(format: "%g", player.playbackRate))x" }

    // MARK: - Touch lock

    private func lock() {
        withAnimation(.easeInOut(duration: 0.2)) {
            locked = true
            showControls = false
        }
        flashUnlock()
    }

    /// While locked: a tap shows the lock badge for a few seconds; holding it unlocks.
    private var lockLayer: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { flashUnlock() }
            if showUnlock {
                VStack(spacing: 8) {
                    Image(systemName: "lock.fill").font(.system(size: 22, weight: .semibold))
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                    Text("Giữ để mở khoá").font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                }
                .foregroundStyle(.white)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.7) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        locked = false
                        showUnlock = false
                        showControls = true
                    }
                    keepControlsVisible()
                }
                .transition(.opacity)
            }
        }
    }

    private func flashUnlock() {
        withAnimation(.easeInOut(duration: 0.2)) { showUnlock = true }
        let shownAt = Date()
        scratch.unlockShownAt = shownAt
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if scratch.unlockShownAt == shownAt { withAnimation(.easeInOut(duration: 0.2)) { showUnlock = false } }
        }
    }

    // MARK: - Gestures

    private func handleDoubleTap(at location: CGPoint, size: CGSize) {
        let seconds = PlayerSettings.doubleTapSeconds
        if location.x < size.width / 3 {
            player.skip(ms: Int32(-seconds * 1000))
            showHint("-\(seconds)s")
        } else if location.x > size.width * 2 / 3 {
            player.skip(ms: Int32(seconds * 1000))
            showHint("+\(seconds)s")
        } else {
            player.togglePlayPause()
        }
    }

    private func playerDragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                if scratch.dragMode == nil {
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    if dx > dy, value.startLocation.x < 30, value.translation.width > 0 {
                        // Swipe in from the left edge = back (close the player), like everywhere else in the app.
                        scratch.dragMode = .edgeBack
                    } else if dx > dy {
                        scratch.dragMode = .seek
                        scratch.seekBaseMs = Int(player.time)
                        scratch.seekOriginDX = value.translation.width
                        scratch.seekPreviewMs = Int(player.time)
                    } else if value.startLocation.x < size.width / 2 {
                        scratch.dragMode = .brightness
                        scratch.dragBaseValue = Double(UIScreen.main.brightness)
                    } else {
                        scratch.dragMode = .volume
                        scratch.dragBaseValue = Double(SystemVolume.current)
                    }
                }
                switch scratch.dragMode {
                case .seek:
                    guard player.duration > 0 else { return }
                    let deltaMs = Int(Double((value.translation.width - scratch.seekOriginDX) / size.width) * 120_000)
                    let newMs = max(0, min(Int(player.duration) - 1000, scratch.seekBaseMs + deltaMs))
                    scratch.seekPreviewMs = newMs
                    let fraction = Double(newMs) / Double(player.duration)
                    hint.set(PlayerTimeRow.format(Int32(newMs)) + "  (" + (deltaMs >= 0 ? "+" : "−") + "\(abs(deltaMs) / 1000)s)",
                             progress: fraction)
                    // The picture, the seek bar and the time follow the finger.
                    scrub.follow(fraction)
                    player.scrub(toMs: Int32(newMs))
                case .brightness:
                    let delta = Double(-value.translation.height / size.height)
                    let newValue = min(1, max(0, scratch.dragBaseValue + delta))
                    UIScreen.main.brightness = newValue
                    hint.set("Độ sáng \(Int(newValue * 100))%")
                case .volume:
                    // System volume: applies instantly (libVLC's own volume lagged behind its audio buffer).
                    let delta = Double(-value.translation.height / size.height) * 1.5
                    let newValue = min(1, max(0, scratch.dragBaseValue + delta))
                    SystemVolume.set(Float(newValue))
                    hint.set("Âm lượng \(Int((newValue * 100).rounded()))%")
                case .edgeBack:
                    hint.set(value.translation.width > 90 ? "← Thoát" : nil)
                case .none:
                    break
                }
            }
            .onEnded { value in
                if scratch.dragMode == .seek, let target = scratch.seekPreviewMs, player.duration > 0 {
                    player.endScrub(atMs: Int32(target))
                    scrub.release(at: Double(target) / Double(player.duration))
                }
                if scratch.dragMode == .edgeBack, value.translation.width > 90 || value.predictedEndTranslation.width > 200 {
                    close()
                }
                scratch.dragMode = nil
                scratch.seekPreviewMs = nil
                hint.set(nil)
            }
    }

    private func endSpeedBoost() {
        guard let rate = scratch.speedBoostFrom else { return }
        player.playbackRate = rate
        scratch.speedBoostFrom = nil
        if hint.text == "2× ▶▶" { hint.set(nil) }
    }

    private func showHint(_ text: String) {
        hint.set(text)
        Task { @MainActor [hint] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if hint.text == text { hint.set(nil) }
        }
    }

    private func cycleSpeed() {
        let speeds = Self.speeds
        let next = speeds.first { $0 > player.playbackRate } ?? speeds[0]
        player.playbackRate = next
    }

    /// Recognition with the settings this folder last used.
    private func startSpeech(on target: LiveSubtitles, source: String, durationMs: Int) {
        let settings = SpeechSettings.shared
        settings.applyFolderPreferences(for: source)
        target.start(source: source, durationMs: durationMs, modelSize: settings.modelSize.rawValue,
                     language: settings.spokenLanguage, translateTo: settings.translateTo,
                     dual: settings.dualSubtitles && settings.translateTo != nil)
    }

    private func playNextOrClose() {
        if queue.moveNext() != nil { player.playCurrent() } else { close() }
    }

    private func close() {
        ResumeStore.clearVideo()
        player.stop()
        onClose()
    }

    private func format(_ ms: Int32) -> String {
        let total = max(0, Int(ms) / 1000)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

/// Owns the VLCMediaPlayer and republishes its state as SwiftUI-observable properties.
final class VlcPlayerController: NSObject, ObservableObject, VLCMediaPlayerDelegate, RemoteControllable {
    let mediaPlayer = VLCMediaPlayer()
    @Published var isPlaying = false
    /// Not @Published: every change used to re-render the entire player 4×/s. The few views that show time observe
    /// `clock` instead; everything else reads these on demand (gestures, background resume...).
    var time: Int32 = 0 { didSet { if clock.time != time { clock.time = time } } }
    var duration: Int32 = 0 { didSet { if clock.duration != duration { clock.duration = duration } } }
    let clock = PlaybackClock()
    @Published var didReachEnd = false
    @Published var showError = false
    /// "Xem tiếp từ 12:34?": where this video was left off last time, offered for a few seconds after it opens.
    @Published var resumeOffer: Int32?
    /// "Tự xem tiếp": opened where it was left off (this position); "Xem từ đầu" shows for a few seconds.
    @Published var resumedFrom: Int32?
    /// "Thời gian phụ đề" (ms, + = later) for the subtitles VLC draws; the sheet sets the app's line to the same.
    /// Back to 0 for every new video.
    @Published var subtitleDelayMs = 0 {
        didSet { if subtitleDelayMs != oldValue { applySubtitleDelay() } }
    }
    private var lastLoggedState = -1
    /// The file playing now (its position is saved when it changes, stops or the app leaves).
    private var currentSource: String?
    private var openedAt: Date?
    private var lastPositionSave = Date.distantPast
    private var warmedNext: String?
    @Published var deinterlaceOn = false
    /// Opening / buffering before the first frame: the player shows a spinner so a slow file does not look dead.
    @Published var isLoading = false

    /// `nil` means "auto" (let VLCKit pick). Cycled by the aspect-ratio button in the player toolbar.
    private static let aspectRatios: [String?] = [nil, "16:9", "4:3", "1:1", "16:10"]
    private var aspectIndex = 0

    var progress: Double { duration > 0 ? Double(time) / Double(duration) : 0 }

    /// Kept here and applied on the VLC control queue: libVLC's rate getter/setter take the player lock.
    private var cachedRate: Float = 1
    var playbackRate: Float {
        get { cachedRate }
        set {
            cachedRate = newValue
            let player = mediaPlayer
            VLCControl.run { player.rate = newValue }
        }
    }

    private var styleObserver: AnyCancellable?

    override init() {
        super.init()
        mediaPlayer.delegate = self
        // Subtitles VLC draws itself (tracks in the file) follow "Kiểu chữ phụ đề", also when it changes mid-video.
        applySubtitleStyle()
        startStallWatch()
        styleObserver = SubtitleStyle.shared.changed
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.applySubtitleStyle() }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    // MARK: - Background / foreground
    //
    // iOS suspends the app in the background and drops its sockets: libVLC was left holding a dead SMB connection
    // (and a video surface it may not draw to in the background), and coming back froze the player. Instead the
    // item is stopped on the way out (position remembered) and reopened at that position on the way back in.

    private var resumeAfterBackground: (item: VideoItem, timeMs: Int32, wasPlaying: Bool)?

    /// "Nghe tiếp khi khoá màn hình": playing on in the background with the picture track off.
    private var soundOnly = false
    private var hiddenVideoTrack: Int32 = -1
    /// Opened while in the background (next episode): without its picture, reopened with it on return.
    private var openedWithoutVideo = false
    /// The last item ended while the screen was locked: the player closes when the app comes back.
    private var endedInBackground = false

    @objc private func didEnterBackground() {
        guard let item = PlaybackQueue.shared.current, mediaPlayer.media != nil, !mediaPlayer.isFinished || time > 0 else { return }
        if PlayerSettings.backgroundAudio, isPlaying {
            // Keep the sound going (the app stays alive while audio plays, so the SMB connection does too); the
            // picture is switched off to save the battery.
            soundOnly = true
            hiddenVideoTrack = mediaPlayer.currentVideoTrackIndex
            let player = mediaPlayer
            VLCControl.run { player.currentVideoTrackIndex = -1 }
            ResumeStore.saveVideo(source: item.source, timeMs: time)
            savePosition()
            RemoteCommands.shared.video = self
            updateNowPlaying()
            PlaybackDiagnostics.append("player: background — sound only at \(time)ms")
            return
        }
        resumeAfterBackground = (item, time, mediaPlayer.isActive)
        // Survives iOS closing the app in the background: the next launch reopens this video here.
        ResumeStore.saveVideo(source: item.source, timeMs: time)
        savePosition()
        PlaybackDiagnostics.append("player: background — stopping at \(time)ms")
        playGeneration += 1
        VLCControl.stop(mediaPlayer)
    }

    @objc private func willEnterForeground() {
        if soundOnly {
            soundOnly = false
            RemoteCommands.shared.video = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            if endedInBackground {
                endedInBackground = false
                openedWithoutVideo = false
                didReachEnd = true
                return
            }
            if let item = PlaybackQueue.shared.current, openedWithoutVideo || !isPlaying {
                // Opened without its picture (next episode), or paused from the lock screen (the app may have been
                // suspended since, its connection gone): reopen here with the picture.
                let wasPlaying = isPlaying
                openedWithoutVideo = false
                PlaybackDiagnostics.append("player: foreground — reopening with the picture at \(time)ms")
                VLCControl.stop(mediaPlayer)
                start(item, resumeAtMs: max(0, time - 1000))
                if !wasPlaying {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self else { return }
                        VLCControl.pause(self.mediaPlayer)
                    }
                }
            } else {
                let player = mediaPlayer
                let track = hiddenVideoTrack
                VLCControl.run {
                    // Back to the track it had (the first picture track if that is unknown).
                    let tracks = (player.videoTrackIndexes as? [NSNumber])?.map(\.int32Value) ?? []
                    player.currentVideoTrackIndex = tracks.contains(track) ? track : (tracks.first { $0 >= 0 } ?? track)
                }
                PlaybackDiagnostics.append("player: foreground — picture back on")
            }
            return
        }
        guard let resume = resumeAfterBackground else { return }
        resumeAfterBackground = nil
        guard resume.item == PlaybackQueue.shared.current else { return }
        PlaybackDiagnostics.append("player: foreground — reopening at \(resume.timeMs)ms")
        start(resume.item, resumeAtMs: max(0, resume.timeMs - 2000))
        if !resume.wasPlaying {
            // Was paused: show the frame at that spot, paused again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                VLCControl.pause(self.mediaPlayer)
            }
        }
    }

    deinit {
        stallTimer?.invalidate()
        // Never release a player that may still be stopping — see VLCControl.
        VLCControl.retire(mediaPlayer)
    }

    /// Which way the current SMB item is being played, and the timer that gives up on the direct route if it has
    /// not started playing in time.
    private var smbRoute: SmbPlaybackRoute = .direct
    private var fallbackWork: DispatchWorkItem?
    private var playGeneration = 0

    /// Plays `PlaybackQueue.shared.current`: a local file directly; an SMB file first straight through libVLC's own
    /// SMB2 module (like the official VLC for iOS app), falling back to the AMSMB2 loopback proxy if that errors
    /// out or has not started playing within 20s.
    func playCurrent() {
        guard let item = PlaybackQueue.shared.current else { return }
        didReachEnd = false
        smbRoute = SmbRoutePreferences.prefersProxy(item.source) ? .proxy : .direct
        triedOtherRoute = false
        if let resume = AppNavigator.shared.pendingResumeMs, resume.source == item.source {
            AppNavigator.shared.pendingResumeMs = nil
            resumeOffer = nil
            PlaybackDiagnostics.append("player: resuming after relaunch at \(resume.ms)ms")
            start(item, resumeAtMs: max(0, resume.ms - 2000))
            return
        }
        resumedFrom = nil
        if let saved = PositionStore.position(for: item.source), PlayerSettings.autoResume {
            // Opened right there (faster than opening at the start and seeking); "Xem từ đầu" for a few seconds.
            resumeOffer = nil
            resumedFrom = saved
            start(item, resumeAtMs: max(0, saved - 2000))
            return
        }
        resumeOffer = PositionStore.position(for: item.source)
        start(item)
    }

    /// "Xem từ đầu" after an automatic resume.
    func startOver() {
        resumedFrom = nil
        let player = mediaPlayer
        VLCControl.run { player.time = VLCTime(int: 0) }
        lastSeekAt = Date()
    }

    /// "Xem tiếp": jump to where it was left off (a couple of seconds earlier, to pick the thread up again).
    func acceptResume() {
        guard let ms = resumeOffer else { return }
        resumeOffer = nil
        let target = max(0, ms - 2000)
        let player = mediaPlayer
        VLCControl.run { player.time = VLCTime(int: target) }
        lastSeekAt = Date()
    }

    /// Saves where the current file is (see `PositionStore`).
    func savePosition() {
        guard let currentSource, duration > 0, time > 0 else { return }
        PositionStore.save(source: currentSource, ms: time, durationMs: duration)
    }

    /// Near the end of a file, the next one in the list is read a little ahead (its header and first megabyte)
    /// so the server has it ready and the next episode starts at once.
    private func warmNextIfNeeded() {
        guard duration > 60_000, time > duration - 45_000, let next = PlaybackQueue.shared.next,
              warmedNext != next.source, let (host, path) = SmbUri.parse(next.source) else { return }
        warmedNext = next.source
        Task.detached(priority: .utility) {
            guard let connection = await SmbRegistry.shared.getOrReconnect(host) else { return }
            _ = await MediaHeaderDuration.lengthMs(host: host, path: path)
            _ = try? await connection.readChunk(path: path, offset: 0, count: 1_048_576)
            if let size = try? await connection.fileSize(path: path), size > 4_194_304 {
                // MP4 index at the end (moov) — libVLC reads it right after the header.
                _ = try? await connection.readChunk(path: path, offset: size - 524_288, count: 524_288)
            }
            PlaybackDiagnostics.append("player: next file warmed up (\(path.split(separator: "/").last ?? ""))")
        }
    }

    /// "Phát bằng chế độ tương thích" / back to normal, from the player's ⋯ menu: switch route for this file,
    /// remember it, and reopen at the current position.
    func switchRoute() {
        guard let item = PlaybackQueue.shared.current, item.isSmb else { return }
        smbRoute = smbRoute == .direct ? .proxy : .direct
        SmbRoutePreferences.set(item.source, proxy: smbRoute == .proxy)
        triedOtherRoute = true
        let at = time
        VLCControl.stop(mediaPlayer)
        start(item, resumeAtMs: at > 0 ? at : nil)
    }

    var isCompatibilityRoute: Bool { smbRoute == .proxy }
    private var triedOtherRoute = false

    private func start(_ item: VideoItem, resumeAtMs: Int32? = nil) {
        fallbackWork?.cancel()
        if currentSource != item.source {
            savePosition()
            currentSource = item.source
            subtitleDelayMs = 0
            stallsThisVideo = 0
        }
        openedAt = Date()
        lastProgressAt = Date()
        inStall = false
        playGeneration += 1
        let generation = playGeneration
        isLoading = true
        duration = 0
        guard let (host, path) = SmbUri.parse(item.source) else {
            guard let local = URL(string: item.source) else { return }
            PlaybackDiagnostics.append("player: local \(item.name)")
            let media = VLCMedia(url: local)
            VLCTuning.apply(to: media, network: false)
            if let resumeAtMs { media.addOption(":start-time=\(Double(resumeAtMs) / 1000)") }
            VLCControl.play(mediaPlayer, media: media)
            return
        }
        let route = smbRoute
        Task { @MainActor in
            let login = await SmbRegistry.shared.login(for: host)
            guard generation == self.playGeneration else { return }
            PlaybackDiagnostics.append("player: \(item.name) route=\(route.rawValue)")
            guard let media = SmbPlayback.media(host: host, path: path, route: route, login: login) else {
                self.fallbackOrFail(item, reason: "could not build media")
                return
            }
            if let resumeAtMs { media.addOption(":start-time=\(Double(resumeAtMs) / 1000)") }
            // The next episode starting while the screen is locked: sound only (no picture surface in the
            // background); the picture comes back when the app does.
            self.openedWithoutVideo = self.soundOnly
            if self.soundOnly { media.addOption(":no-video") }
            VLCControl.play(self.mediaPlayer, media: media)
            // A subtitle added from OpenSubtitles for this file comes back with it.
            if let subtitle = self.addedSubtitles[item.source] {
                let player = self.mediaPlayer
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    VLCControl.run { _ = player.addPlaybackSlave(subtitle, type: .subtitle, enforce: true) }
                }
            }
            // No "not playing after N seconds → switch route" timer any more: MP4s whose audio and video are not
            // interleaved take a long time to start over SMB (libVLC seeks back and forth), and that timer killed
            // them just before they started — while the fallback proxy never works against this server anyway.
            // The proxy is only tried when libVLC reports an actual error.
        }
    }

    /// Direct route failed → retry once through the proxy; proxy failed too → show the error.
    private func fallbackOrFail(_ item: VideoItem, reason: String) {
        PlaybackDiagnostics.append("player: \(smbRoute.rawValue) failed (\(reason))")
        if item.isSmb && !triedOtherRoute {
            triedOtherRoute = true
            smbRoute = smbRoute == .direct ? .proxy : .direct
            PlaybackDiagnostics.append("player: retrying via \(smbRoute.rawValue)")
            VLCControl.stop(mediaPlayer)
            start(item)
        } else {
            isLoading = false
            showError = true
        }
    }

    func togglePlayPause() {
        VLCControl.toggle(mediaPlayer)
    }

    func seek(to fraction: Double) {
        let player = mediaPlayer
        VLCControl.run { player.position = Float(fraction) }
        lastSeekAt = Date()
    }

    // MARK: - Live seeking (a finger on the video or on the seek bar)

    /// The newest spot the finger asked for, not sent to libVLC yet.
    private var scrubTarget: Int32?
    /// The seek libVLC is doing now: done when it reports a time near it (or after 0.35 s).
    private var scrubInFlight: (target: Int32, at: Date)?
    private var scrubRetry: DispatchWorkItem?
    private var lastScrubSent: Int32?
    /// The longest a live seek holds the next one back (0.6 s at first; a seek on the home network mostly lands
    /// sooner, and libVLC reporting the new time releases the next one earlier anyway).
    private static let scrubTimeout: TimeInterval = 0.35

    /// The finger moved: the picture follows it — one seek at a time and only to the newest spot. (Seeking only on
    /// release left the picture standing still during the whole drag; a seek per movement would pile up in libVLC.)
    func scrub(toMs target: Int32) {
        scrubTarget = target
        sendScrubIfReady()
    }

    private func sendScrubIfReady() {
        guard let target = scrubTarget else { return }
        if let flight = scrubInFlight {
            let elapsed = Date().timeIntervalSince(flight.at)
            if elapsed < Self.scrubTimeout {
                // Sent when libVLC reports the previous one done, or when that takes too long.
                if scrubRetry == nil {
                    let work = DispatchWorkItem { [weak self] in
                        self?.scrubRetry = nil
                        self?.scrubInFlight = nil
                        self?.sendScrubIfReady()
                    }
                    scrubRetry = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + (Self.scrubTimeout - elapsed), execute: work)
                }
                return
            }
        }
        scrubTarget = nil
        // Barely moved since the last one: not worth a seek (the exact spot is sent on release).
        if let last = lastScrubSent, abs(Int(last) - Int(target)) < 250 { return }
        scrubInFlight = (target, Date())
        lastSeekAt = Date()
        lastScrubSent = target
        let player = mediaPlayer
        VLCControl.run { player.time = VLCTime(int: target) }
    }

    /// The finger lifted: the exact spot, shown by the clock at once (no snapping back while libVLC catches up).
    func endScrub(atMs target: Int32) {
        scrubRetry?.cancel()
        scrubRetry = nil
        scrubTarget = nil
        scrubInFlight = nil
        if lastScrubSent != target {
            let player = mediaPlayer
            VLCControl.run { player.time = VLCTime(int: target) }
        }
        lastScrubSent = nil
        showSeekTarget(target)
        if let currentSource { PlaybackDiagnostics.append("player: seek to \(target)ms (\(currentSource.split(separator: "/").last ?? ""))") }
    }

    func skip(ms: Int32) {
        let newTime = max(0, mediaPlayer.time.intValue + ms)
        let player = mediaPlayer
        VLCControl.run { player.time = VLCTime(int: newTime) }
        showSeekTarget(newTime)
    }

    /// A seek just asked for: the clock shows `target` right away and ignores libVLC's old position for up to 2.5 s.
    private var pendingSeek: (target: Int32, until: Date)?

    private func showSeekTarget(_ target: Int32) {
        pendingSeek = (target, Date().addingTimeInterval(2.5))
        lastSeekAt = Date()
        time = target
    }

    // MARK: - Stall watch
    //
    // A smaller network buffer starts and seeks faster but has less to fall back on. Playing with the time standing
    // still for 1.5 s (not paused, not just seeked or opened) is a stall; two in one video raise the buffer a step
    // for the next videos (Cài đặt → Trình phát → Bộ đệm mạng).

    private var lastSeekAt = Date.distantPast
    private var lastProgressAt = Date()
    private var lastProgressMs: Int32 = -1
    private var stallsThisVideo = 0
    private var inStall = false
    private var stallTimer: Timer?

    private func startStallWatch() {
        stallTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkStall() }
    }

    private func noteProgress(_ now: Int32) {
        guard now != lastProgressMs else { return }
        lastProgressMs = now
        lastProgressAt = Date()
        inStall = false
    }

    private func checkStall() {
        guard isPlaying, !isLoading, !soundOnly, !inStall,
              UIApplication.shared.applicationState == .active,
              pendingSeek == nil, scrubInFlight == nil,
              Date().timeIntervalSince(lastSeekAt) > 3,
              Date().timeIntervalSince(lastProgressAt) > 1.5 else { return }
        inStall = true
        stallsThisVideo += 1
        PlaybackDiagnostics.append("player: stalled waiting for data (\(stallsThisVideo) in this video, buffer \(PlayerSettings.networkCachingMs) ms)")
        if stallsThisVideo == 2, let raised = PlayerSettings.raiseCaching() {
            PlaybackDiagnostics.append("player: network buffer raised to \(raised) ms for the next videos")
        }
    }

    func stop() {
        savePosition()
        fallbackWork?.cancel()
        playGeneration += 1
        VLCControl.stop(mediaPlayer)
        if soundOnly {
            // Closed in the background (the last episode ended): nothing left on the lock screen.
            soundOnly = false
            openedWithoutVideo = false
            endedInBackground = false
            RemoteCommands.shared.video = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    func cycleAspectRatio() {
        aspectIndex = (aspectIndex + 1) % Self.aspectRatios.count
        if let ratio = Self.aspectRatios[aspectIndex] {
            mediaPlayer.videoAspectRatio = strdup(ratio)
        } else {
            mediaPlayer.videoAspectRatio = nil
        }
    }

    func toggleDeinterlace() {
        deinterlaceOn.toggle()
        mediaPlayer.setDeinterlace(deinterlaceOn ? .auto : .off, withFilter: "blend")
    }

    // MARK: - Tracks
    //
    // MobileVLCKit 3.7.3 (the CocoaPods release actually installed — newer track APIs seen in vlckit's git history
    // are not in this release yet) exposes tracks as two parallel arrays: names and the "index" value you assign back
    // to select that track. `videoSubTitlesNames`/`Indexes` already include a "Disabled" entry (index -1).

    struct TrackOption: Identifiable { let id: Int32; let name: String }

    var audioTrackOptions: [TrackOption] {
        let names = (mediaPlayer.audioTrackNames as? [String]) ?? []
        let indexes = (mediaPlayer.audioTrackIndexes as? [NSNumber]) ?? []
        return zip(indexes, names).map { TrackOption(id: $0.0.int32Value, name: $0.1) }
    }

    var subtitleTrackOptions: [TrackOption] {
        let names = (mediaPlayer.videoSubTitlesNames as? [String]) ?? []
        let indexes = (mediaPlayer.videoSubTitlesIndexes as? [NSNumber]) ?? []
        return zip(indexes, names).map { TrackOption(id: $0.0.int32Value, name: $0.1) }
    }

    var currentAudioTrack: Int32 {
        get { mediaPlayer.currentAudioTrackIndex }
        set { mediaPlayer.currentAudioTrackIndex = newValue; objectWillChange.send() }
    }

    private func applySubtitleDelay() {
        let player = mediaPlayer
        let microseconds = subtitleDelayMs * 1000
        VLCControl.run { player.currentVideoSubTitleDelay = microseconds }
    }

    // MARK: - Lock screen (sound only in the background)

    private func updateNowPlaying() {
        guard soundOnly else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: PlaybackQueue.shared.current?.name ?? "",
            MPMediaItemPropertyPlaybackDuration: Double(duration) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(mediaPlayer.time.intValue) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: mediaPlayer.isPlaying ? Double(cachedRate) : 0.0,
        ]
        if let artwork = nowPlayingArtwork, artwork.source == currentSource {
            let image = artwork.image
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        } else if let source = currentSource {
            // The video's thumbnail as the lock screen picture.
            Task { [weak self] in
                guard let image = await ThumbnailService.shared.cachedThumbnail(source: source) else { return }
                await MainActor.run {
                    self?.nowPlayingArtwork = (source, image)
                    self?.updateNowPlaying()
                }
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private var nowPlayingArtwork: (source: String, image: UIImage)?

    func remotePlay() { VLCControl.play(mediaPlayer) }
    func remotePause() { VLCControl.pause(mediaPlayer) }
    func remoteTogglePlayPause() { togglePlayPause() }

    func remoteNext() {
        if PlaybackQueue.shared.moveNext() != nil { playCurrent() }
    }

    func remotePrevious() {
        if PlaybackQueue.shared.movePrevious() != nil { playCurrent() }
    }

    func remoteSeek(toSeconds seconds: Double) {
        let player = mediaPlayer
        VLCControl.run { player.time = VLCTime(int: Int32(seconds * 1000)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.updateNowPlaying() }
    }

    private func applySubtitleStyle() {
        let player = mediaPlayer
        let settings = SubtitleStyle.shared.vlcSettings
        VLCControl.run { SubtitleStyle.apply(settings, to: player) }
    }

    /// A downloaded subtitle the app cannot read itself (OpenSubtitles' rare formats) becomes a subtitle track of this
    /// video, drawn by VLC. Remembered so it comes back when the video is reopened after the app was in the background.
    func addSubtitleFile(_ url: URL) {
        if let source = currentSource { addedSubtitles[source] = url }
        let player = mediaPlayer
        VLCControl.run { _ = player.addPlaybackSlave(url, type: .subtitle, enforce: true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.objectWillChange.send() }
    }
    private var addedSubtitles: [String: URL] = [:]
    /// The video whose subtitle (from OpenSubtitles) the app draws itself — VLC's own subtitle stays off for it.
    var appDrawnSubtitleSource: String?

    var currentSubtitleTrack: Int32 {
        get { mediaPlayer.currentVideoSubTitleIndex }
        set {
            let player = mediaPlayer
            VLCControl.run { player.currentVideoSubTitleIndex = newValue }
            objectWillChange.send()
        }
    }

    // MARK: - Picture adjustment (VLCAdjustFilter — contrast/brightness/hue/saturation/gamma)

    private func filterValue(_ parameter: VLCFilterParameterProtocol?) -> Float {
        (parameter?.value as? NSNumber)?.floatValue ?? 1
    }

    private func setFilterValue(_ parameter: VLCFilterParameterProtocol?, _ newValue: Float) {
        parameter?.value = NSNumber(value: newValue)
    }

    var contrast: Float {
        get { filterValue(mediaPlayer.adjustFilter.contrast) }
        set { setFilterValue(mediaPlayer.adjustFilter.contrast, newValue) }
    }
    var brightness: Float {
        get { filterValue(mediaPlayer.adjustFilter.brightness) }
        set { setFilterValue(mediaPlayer.adjustFilter.brightness, newValue) }
    }
    var hue: Float {
        get { filterValue(mediaPlayer.adjustFilter.hue) }
        set { setFilterValue(mediaPlayer.adjustFilter.hue, newValue) }
    }
    var saturation: Float {
        get { filterValue(mediaPlayer.adjustFilter.saturation) }
        set { setFilterValue(mediaPlayer.adjustFilter.saturation, newValue) }
    }
    var gamma: Float {
        get { filterValue(mediaPlayer.adjustFilter.gamma) }
        set { setFilterValue(mediaPlayer.adjustFilter.gamma, newValue) }
    }

    func resetPicture() {
        mediaPlayer.adjustFilter.resetParametersIfNeeded()
        objectWillChange.send()
    }

    // MARK: - VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ notification: Notification) {
        DispatchQueue.main.async {
            self.isPlaying = self.mediaPlayer.isActive
            if self.mediaPlayer.state == .error || self.mediaPlayer.state == .ended { self.isLoading = false }
            // Only real changes: VLCKit repeats the same state (buffering…) dozens of times a second — 41,750 lines
            // in one real log.
            let state = self.mediaPlayer.state.rawValue
            if state != self.lastLoggedState {
                self.lastLoggedState = state
                PlaybackDiagnostics.append("player: state=\(state)")
            }
            PlayerTrace.last = "state \(self.mediaPlayer.state.rawValue) at \(self.time)ms"
            if self.soundOnly { self.updateNowPlaying() }
            switch self.mediaPlayer.state {
            case .ended:
                if let source = self.currentSource { PositionStore.markWatched(source, durationMs: self.duration) }
                if self.soundOnly {
                    // Screen locked: the next episode is started from here (the screen's own "next" waits for the
                    // app to come back); after the last one the player closes on return.
                    if PlaybackQueue.shared.moveNext() != nil { self.playCurrent() } else { self.endedInBackground = true }
                } else {
                    self.didReachEnd = true
                }
            case .error:
                if let item = PlaybackQueue.shared.current { self.fallbackOrFail(item, reason: "VLC error") }
                else { self.showError = true }
            default: break
            }
        }
    }

    func mediaPlayerTimeChanged(_ notification: Notification) {
        DispatchQueue.main.async {
            let previous = self.time
            let now = self.mediaPlayer.time.intValue
            self.noteProgress(now)
            // A live seek got there: the next one can go.
            if let flight = self.scrubInFlight, Date().timeIntervalSince(flight.at) > 0.08,
               abs(Int(now) - Int(flight.target)) < 2500 {
                self.scrubInFlight = nil
                self.scrubRetry?.cancel()
                self.scrubRetry = nil
                self.sendScrubIfReady()
            }
            // Right after a seek libVLC still reports the old spot for a moment: keep showing the new one.
            if let pending = self.pendingSeek {
                if abs(Int(now) - Int(pending.target)) < 2500 || Date() > pending.until {
                    self.pendingSeek = nil
                } else {
                    return
                }
            }
            // Republish at most ~4x/s: each change re-renders the whole player view.
            if now > 0, self.isLoading { self.isLoading = false }
            guard abs(now - previous) >= 250 || now < previous else { return }
            self.time = now
            // Length once per file (VLCKit keeps querying libVLC while it is unknown).
            if self.duration <= 0 { self.duration = self.mediaPlayer.media?.length.intValue ?? 0 }
            PlayerTrace.last = "time \(now)ms"
            if let openedAt = self.openedAt, now > 0 {
                self.openedAt = nil
                PlaybackDiagnostics.append(String(format: "player: playing after %.1fs", Date().timeIntervalSince(openedAt)))
                // Reopened (after the background) while the app draws a downloaded subtitle: the file's default
                // subtitle track, picked again by VLC, would show underneath.
                if let source = self.currentSource, self.appDrawnSubtitleSource == source {
                    let player = self.mediaPlayer
                    VLCControl.run { player.currentVideoSubTitleIndex = -1 }
                }
                // VLC forgets the subtitle timing when the file is reopened (route switch, background).
                if self.subtitleDelayMs != 0 { self.applySubtitleDelay() }
                if self.soundOnly { self.updateNowPlaying() }
            }
            if Date().timeIntervalSince(self.lastPositionSave) > 15 {
                self.lastPositionSave = Date()
                self.savePosition()
            }
            // A resume offer only makes sense near the start.
            if self.resumeOffer != nil, now > 20_000 { self.resumeOffer = nil }
            self.warmNextIfNeeded()
            // Proof of actual playback in the log (every ~5s of media time), not just "state=playing".
            if self.time / 5000 != previous / 5000 || (previous == 0 && self.time > 0) {
                PlaybackDiagnostics.append("player: time=\(self.time)ms / \(self.duration)ms")
            }
        }
    }
}

/// Hosts VLCKit's drawable view (a plain UIView it renders video into).
struct VlcVideoView: UIViewRepresentable {
    let player: VlcPlayerController

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        // Touches never go to libVLC's vout view; the SwiftUI overlay above handles them.
        view.isUserInteractionEnabled = false
        player.mediaPlayer.drawable = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Contrast / brightness / hue / saturation / gamma sliders backed by VLCKit's `VLCAdjustFilter`.
struct PictureControlsSheet: View {
    @ObservedObject var player: VlcPlayerController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                slider("Độ tương phản", value: Binding(get: { player.contrast }, set: { player.contrast = $0 }), range: 0...2)
                slider("Độ sáng", value: Binding(get: { player.brightness }, set: { player.brightness = $0 }), range: 0...2)
                slider("Sắc độ", value: Binding(get: { player.hue }, set: { player.hue = $0 }), range: -180...180)
                slider("Độ bão hòa", value: Binding(get: { player.saturation }, set: { player.saturation = $0 }), range: 0...3)
                slider("Gamma", value: Binding(get: { player.gamma }, set: { player.gamma = $0 }), range: 0...10)
                Button("Đặt lại mặc định") { player.resetPicture() }
            }
            .navigationTitle("Chỉnh hình ảnh")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func slider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.subheadline)
            Slider(value: value, in: range)
        }
    }
}

/// The player's seek bar: tap anywhere on it to jump straight there, or drag to scrub (the video only seeks when the
/// finger lifts). A 36pt-tall touch area around a thin track, so it is easy to hit.
struct SeekBar: View {
    let progress: Double
    var tint: AnyShapeStyle = AnyShapeStyle(Color.white)
    var track: Color = .white.opacity(0.3)
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let x = CGFloat(min(max(progress, 0), 1)) * width
            ZStack(alignment: .leading) {
                Capsule().fill(track).frame(height: dragging ? 6 : 4)
                Capsule().fill(tint).frame(width: x, height: dragging ? 6 : 4)
                Circle().fill(tint)
                    .frame(width: dragging ? 20 : 14, height: dragging ? 20 : 14)
                    .offset(x: x - (dragging ? 10 : 7))
            }
            .frame(height: 36)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        onScrub(fraction(value.location.x, width))
                    }
                    .onEnded { value in
                        dragging = false
                        onCommit(fraction(value.location.x, width))
                    }
            )
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: 36)
    }

    private func fraction(_ x: CGFloat, _ width: CGFloat) -> Double {
        Double(min(max(x / width, 0), 1))
    }
}

/// The files of the folder the video was opened from, with thumbnails, to pick what to play next.
struct PlayQueueSheet: View {
    @ObservedObject var queue: PlaybackQueue
    let onPick: (Int) -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(Array(queue.items.enumerated()), id: \.element.id) { index, item in
                    Button { onPick(index) } label: {
                        HStack(spacing: 12) {
                            VideoThumbnailView(source: item.source, size: 54)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).lineLimit(2)
                                    .fontWeight(index == queue.index ? .semibold : .regular)
                                    .foregroundStyle(index == queue.index ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                                if item.sizeBytes > 0 {
                                    Text(item.sizeLabel).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if index == queue.index {
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                            }
                        }
                    }
                    .id(index)
                }
                .listStyle(.plain)
                .onAppear { proxy.scrollTo(queue.index, anchor: .center) }
            }
            .navigationTitle("Trong thư mục (\(queue.items.count))")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

/// Current playback time for the few views that display it.
final class PlaybackClock: ObservableObject {
    @Published var time: Int32 = 0
    @Published var duration: Int32 = 0
    var progress: Double { duration > 0 ? Double(time) / Double(duration) : 0 }
}

/// Elapsed / seek bar / total — the only part of the controls that changes several times a second.
private struct PlayerTimeRow: View {
    @ObservedObject var clock: PlaybackClock
    let live: LiveSubtitles
    @ObservedObject var scrub: ScrubState
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void
    @AppStorage(PlayerSettings.remainingKey) private var showRemaining = false

    var body: some View {
        Text(Self.format(scrub.seeking ? Int32(scrub.value * Double(clock.duration)) : clock.time))
            .foregroundStyle(.white).font(.caption).monospacedDigit()
        SeekBar(progress: scrub.seeking ? scrub.value : clock.progress, tint: AnyShapeStyle(.tint), onScrub: onScrub, onCommit: onCommit)
            .overlay { SubtitleMarksBar(live: live).offset(y: 7).allowsHitTesting(false) }
        // Tap: total length ⇄ time left.
        Text(showRemaining ? "-" + Self.format(max(0, clock.duration - clock.time)) : Self.format(clock.duration))
            .foregroundStyle(.white).font(.caption).monospacedDigit()
            .contentShape(Rectangle())
            .onTapGesture { showRemaining.toggle() }
    }

    static func format(_ ms: Int32) -> String {
        let total = max(0, Int(ms) / 1000)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

/// The app's subtitle line on screen (AI subtitles, subtitles from OpenSubtitles), following the clock.
private struct LiveCueOverlay: View {
    @ObservedObject var clock: PlaybackClock
    @ObservedObject var live: LiveSubtitles

    var body: some View {
        VStack {
            Spacer()
            if let cue = live.activeCue(at: Int(clock.time) - live.delayMs) {
                SubtitleLineView(text: cue.text)
                    .padding(.horizontal, 24)
            }
        }
    }
}

/// "🎙 Đang nhận dạng…" / translation queue note, top-left.
private struct LiveStatusBadge: View {
    @ObservedObject var live: LiveSubtitles

    var body: some View {
        if let status = live.running ? live.status : live.translationNote {
            VStack {
                HStack {
                    Text("🎙 \(status)")
                        .font(.caption).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Capsule())
                    Spacer()
                }
                .padding(.top, 60).padding(.horizontal)
                Spacer()
            }
            .allowsHitTesting(false)
        }
    }
}

/// After an automatic resume: "Đang xem tiếp từ 12:34" with a "Xem từ đầu" button, for a few seconds.
private struct StartOverBanner: View {
    let timeText: String
    let onStartOver: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("Xem tiếp từ \(timeText)", systemImage: "clock.arrow.circlepath")
                .font(.subheadline)
                .foregroundStyle(.white)
            Button(action: onStartOver) {
                Label("Xem từ đầu", systemImage: "backward.end.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.tint))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.6)))
    }
}

/// "Xem tiếp từ 12:34" / "Từ đầu" — shown over the video for a few seconds when it was watched before.
private struct ResumeBanner: View {
    let timeText: String
    let onResume: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onResume) {
                Label("Xem tiếp từ \(timeText)", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Capsule().fill(.tint))
                    .foregroundStyle(.white)
            }
            Button(action: onDismiss) {
                Text("Từ đầu").font(.subheadline)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Under the seek bar: where AI subtitles already exist (blue) and lines still waiting for a translation (orange).
private struct SubtitleMarksBar: View {
    @ObservedObject var live: LiveSubtitles

    var body: some View {
        let marks = live.marks
        if !marks.covered.isEmpty {
            Canvas { context, size in
                for span in marks.covered {
                    let rect = CGRect(x: span.lowerBound * size.width, y: 0,
                                      width: max(1, (span.upperBound - span.lowerBound) * size.width), height: size.height)
                    context.fill(Path(rect), with: .color(Color.cyan.opacity(0.7)))
                }
                for spot in marks.untranslated {
                    context.fill(Path(CGRect(x: spot * size.width, y: 0, width: 1.5, height: size.height)),
                                 with: .color(.orange))
                }
            }
            .frame(height: 3)
        }
    }
}

/// Seek-bar scrubbing state, observed only by `PlayerTimeRow`.
final class ScrubState: ObservableObject {
    @Published var seeking = false
    @Published var value: Double = 0
    /// Bumped by every drag movement, so a "let go" hold from an earlier drag does not end a newer one.
    var generation = 0

    /// The finger lifted: keep showing `value` a moment, until libVLC reports the new position.
    func release(at fraction: Double) {
        value = fraction
        generation += 1
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            if self?.generation == mine { self?.seeking = false }
        }
    }

    func follow(_ fraction: Double) {
        generation += 1
        if !seeking { seeking = true }
        value = fraction
    }
}

/// What the player's gestures keep between movements but never draw — a plain object held in @State, so writing
/// to it does not redraw the player (it did, 60–120 times a second while a finger moved: seek / volume / brightness).
private final class GestureScratch {
    var dragMode: PlayerDragMode?
    var dragBaseValue: Double = 0
    var seekPreviewMs: Int?
    /// Where the video was when the seek drag began, and how far the finger had already moved then — the target is
    /// counted from these (the video's own time moves while seeking live, so it cannot be the base).
    var seekBaseMs = 0
    var seekOriginDX: CGFloat = 0
    /// Rate to go back to when the press-and-hold 2× boost ends.
    var speedBoostFrom: Float?
    var hideAt = Date.distantPast
    var hideTimerRunning = false
    /// When the lock badge was last shown (it hides 2.5 s later unless shown again meanwhile).
    var unlockShownAt: Date?
}

/// The gesture bubble's text; only `GestureHintView` observes it.
final class GestureHint: ObservableObject {
    @Published private(set) var text: String?
    /// While seeking: where in the video (0…1), drawn as a bar under the text.
    @Published private(set) var progress: Double?
    func set(_ new: String?, progress newProgress: Double? = nil) {
        if text != new { text = new }
        if progress != newProgress { progress = newProgress }
    }
}

private struct GestureHintView: View {
    @ObservedObject var hint: GestureHint

    var body: some View {
        if let text = hint.text {
            VStack(spacing: 8) {
                Text(text)
                    .font(.headline.monospacedDigit()).foregroundStyle(.white)
                if let progress = hint.progress {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.3))
                        Capsule().fill(.tint).frame(width: 200 * CGFloat(min(max(progress, 0), 1)))
                    }
                    .frame(width: 200, height: 4)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color.black.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: hint.progress == nil ? 20 : 14, style: .continuous))
            .allowsHitTesting(false)
        }
    }
}
