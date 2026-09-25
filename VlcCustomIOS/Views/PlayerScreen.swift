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
    @State private var seeking = false
    @State private var sliderValue: Double = 0
    @State private var showControls = true
    @State private var showTrackPicker = false
    @State private var showPictureControls = false
    @State private var showSpeechDialog = false
    @StateObject private var live = LiveSubtitles.shared

    // Gesture state — mirrors the Android player: horizontal drag seeks, vertical drag on the left half adjusts
    // screen brightness and on the right half adjusts VLC's own volume, double-tap on either side skips ±30s and
    // double-tap in the middle toggles play/pause.
    @State private var dragMode: PlayerDragMode?
    @State private var dragBaseValue: Double = 0
    @State private var seekPreviewMs: Int?
    @State private var gestureHint: String?
    @State private var controlsHideToken = 0
    @State private var showQueue = false

    private static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        GeometryReader { geo in
        ZStack {
            Color.black.ignoresSafeArea()
            VlcVideoView(player: player).ignoresSafeArea()
                .allowsHitTesting(false)

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

            if let gestureHint {
                Text(gestureHint)
                    .font(.headline).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.black.opacity(0.7))
                    .clipShape(Capsule())
            }

            VStack {
                Spacer()
                if let cue = live.activeCue(at: Int(player.time)) {
                    Text(cue.text)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.black.opacity(0.65))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(.horizontal, 24)
                }
            }
            .padding(.bottom, showControls ? 230 : 28)
            .allowsHitTesting(false)

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

            if showControls {
                VStack(spacing: 0) {
                    // Top bar: close + file name only. All tools sit in the bottom panel as roomy 44pt round
                    // buttons, the rarer ones (aspect, deinterlace, picture) tucked into a "more" menu.
                    HStack(spacing: 10) {
                        controlButton("xmark") { close() }
                        Text(queue.current?.name ?? "")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.white).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))

                    Spacer()

                    VStack(spacing: 14) {
                        HStack(spacing: 10) {
                            Text(format(player.time)).foregroundStyle(.white).font(.caption).monospacedDigit()
                            SeekBar(progress: seeking ? sliderValue : player.progress,
                                    onScrub: { fraction in
                                        seeking = true
                                        sliderValue = fraction
                                        keepControlsVisible()
                                    },
                                    onCommit: { fraction in
                                        sliderValue = fraction
                                        player.seek(to: fraction)
                                        keepControlsVisible()
                                        // Hold the new position until VLC reports it, instead of snapping back.
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { seeking = false }
                                    })
                            Text(format(player.duration)).foregroundStyle(.white).font(.caption).monospacedDigit()
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
                            controlButton("captions.bubble") { showTrackPicker = true }
                            controlButton("waveform") { showSpeechDialog = true }
                            Menu {
                                Button { player.cycleAspectRatio() } label: { Label("Tỉ lệ khung hình", systemImage: "aspectratio") }
                                Button { player.toggleDeinterlace() } label: {
                                    Label(player.deinterlaceOn ? "Tắt khử sọc" : "Bật khử sọc", systemImage: "tv")
                                }
                                Button { showPictureControls = true } label: { Label("Chỉnh màu", systemImage: "slider.horizontal.3") }
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
        .onAppear {
            MusicUI.shared.videoOpened()
            player.playCurrent(); PlaybackActivity.shared.isBusy = true; keepControlsVisible()
        }
        .onDisappear {
            player.stop(); live.stop(); PlaybackActivity.shared.isBusy = false
            OrientationLock.unlock()
        }
        .onChange(of: player.didReachEnd) { reached in if reached { playNextOrClose() } }
        .alert("Không phát được video", isPresented: $player.showError) {
            Button("Đóng", role: .cancel) {}
        } message: {
            Text("Định dạng/codec chưa được hỗ trợ, file lỗi hoặc mất kết nối mạng (nếu là video từ SMB).")
        }
        .sheet(isPresented: $showQueue) {
            PlayQueueSheet(queue: queue) { index in
                showQueue = false
                queue.jump(to: index)
                player.playCurrent()
            }
        }
        .sheet(isPresented: $showTrackPicker) {
            TrackPickerSheet(player: player)
        }
        .sheet(isPresented: $showPictureControls) {
            PictureControlsSheet(player: player)
        }
        .sheet(isPresented: $showSpeechDialog) {
            SpeechSubtitleDialog(live: live, videoName: queue.current?.name ?? "", durationMs: Int(player.duration), source: queue.current?.source ?? "")
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
    private func keepControlsVisible() {
        controlsHideToken += 1
        let token = controlsHideToken
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if token == controlsHideToken, player.isPlaying, !seeking, !showTrackPicker, !showPictureControls, !showSpeechDialog, !showQueue {
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

    // MARK: - Gestures

    private func handleDoubleTap(at location: CGPoint, size: CGSize) {
        if location.x < size.width / 3 {
            player.skip(ms: -30_000)
            showHint("-30s")
        } else if location.x > size.width * 2 / 3 {
            player.skip(ms: 30_000)
            showHint("+30s")
        } else {
            player.togglePlayPause()
        }
    }

    private func playerDragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                if dragMode == nil {
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    if dx > dy, value.startLocation.x < 30, value.translation.width > 0 {
                        // Swipe in from the left edge = back (close the player), like everywhere else in the app.
                        dragMode = .edgeBack
                    } else if dx > dy {
                        dragMode = .seek
                        seekPreviewMs = Int(player.time)
                    } else if value.startLocation.x < size.width / 2 {
                        dragMode = .brightness
                        dragBaseValue = Double(UIScreen.main.brightness)
                    } else {
                        dragMode = .volume
                        dragBaseValue = Double(SystemVolume.current)
                    }
                }
                switch dragMode {
                case .seek:
                    guard player.duration > 0 else { return }
                    let deltaMs = Int(Double(value.translation.width / size.width) * 120_000)
                    let newMs = max(0, min(Int(player.duration), Int(player.time) + deltaMs))
                    seekPreviewMs = newMs
                    gestureHint = (deltaMs >= 0 ? "+" : "") + "\(deltaMs / 1000)s"
                case .brightness:
                    let delta = Double(-value.translation.height / size.height)
                    let newValue = min(1, max(0, dragBaseValue + delta))
                    UIScreen.main.brightness = newValue
                    gestureHint = "Độ sáng \(Int(newValue * 100))%"
                case .volume:
                    // System volume: applies instantly (libVLC's own volume lagged behind its audio buffer).
                    let delta = Double(-value.translation.height / size.height) * 1.5
                    let newValue = min(1, max(0, dragBaseValue + delta))
                    SystemVolume.set(Float(newValue))
                    gestureHint = "Âm lượng \(Int((newValue * 100).rounded()))%"
                case .edgeBack:
                    gestureHint = value.translation.width > 90 ? "← Thoát" : nil
                case .none:
                    break
                }
            }
            .onEnded { value in
                if dragMode == .seek, let seekPreviewMs, player.duration > 0 {
                    player.seek(to: Double(seekPreviewMs) / Double(player.duration))
                }
                if dragMode == .edgeBack, value.translation.width > 90 || value.predictedEndTranslation.width > 200 {
                    close()
                }
                dragMode = nil
                seekPreviewMs = nil
                gestureHint = nil
            }
    }

    private func showHint(_ text: String) {
        gestureHint = text
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if gestureHint == text { gestureHint = nil }
        }
    }

    private func cycleSpeed() {
        let speeds = Self.speeds
        let next = speeds.first { $0 > player.playbackRate } ?? speeds[0]
        player.playbackRate = next
    }

    private func playNextOrClose() {
        if queue.moveNext() != nil { player.playCurrent() } else { close() }
    }

    private func close() {
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
final class VlcPlayerController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let mediaPlayer = VLCMediaPlayer()
    @Published var isPlaying = false
    @Published var time: Int32 = 0
    @Published var duration: Int32 = 0
    @Published var didReachEnd = false
    @Published var showError = false
    @Published var deinterlaceOn = false

    /// `nil` means "auto" (let VLCKit pick). Cycled by the aspect-ratio button in the player toolbar.
    private static let aspectRatios: [String?] = [nil, "16:9", "4:3", "1:1", "16:10"]
    private var aspectIndex = 0

    var progress: Double { duration > 0 ? Double(time) / Double(duration) : 0 }

    var playbackRate: Float {
        get { mediaPlayer.rate }
        set { mediaPlayer.rate = newValue }
    }

    override init() {
        super.init()
        mediaPlayer.delegate = self
    }

    deinit {
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
        smbRoute = .direct
        start(item)
    }

    private func start(_ item: VideoItem) {
        fallbackWork?.cancel()
        playGeneration += 1
        let generation = playGeneration
        guard let (host, path) = SmbUri.parse(item.source) else {
            guard let local = URL(string: item.source) else { return }
            PlaybackDiagnostics.append("player: local \(item.name)")
            VLCControl.play(mediaPlayer, media: VLCMedia(url: local))
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
            VLCControl.play(self.mediaPlayer, media: media)
            if route == .direct {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, generation == self.playGeneration, self.time == 0 else { return }
                    self.fallbackOrFail(item, reason: "direct route not playing after 20s")
                }
                self.fallbackWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
            }
        }
    }

    /// Direct route failed → retry once through the proxy; proxy failed too → show the error.
    private func fallbackOrFail(_ item: VideoItem, reason: String) {
        PlaybackDiagnostics.append("player: \(smbRoute.rawValue) failed (\(reason))")
        if item.isSmb && smbRoute == .direct {
            smbRoute = .proxy
            VLCControl.stop(mediaPlayer)
            start(item)
        } else {
            showError = true
        }
    }

    func togglePlayPause() {
        VLCControl.toggle(mediaPlayer)
    }

    func seek(to fraction: Double) {
        let player = mediaPlayer
        VLCControl.run { player.position = Float(fraction) }
    }

    func skip(ms: Int32) {
        let newTime = max(0, mediaPlayer.time.intValue + ms)
        let player = mediaPlayer
        VLCControl.run { player.time = VLCTime(int: newTime) }
    }

    func stop() {
        fallbackWork?.cancel()
        playGeneration += 1
        VLCControl.stop(mediaPlayer)
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

    var currentSubtitleTrack: Int32 {
        get { mediaPlayer.currentVideoSubTitleIndex }
        set { mediaPlayer.currentVideoSubTitleIndex = newValue; objectWillChange.send() }
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
            PlaybackDiagnostics.append("player: state=\(self.mediaPlayer.state.rawValue)")
            switch self.mediaPlayer.state {
            case .ended: self.didReachEnd = true
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
            // Republish at most ~4x/s: each change re-renders the whole player view.
            guard abs(now - previous) >= 250 || now < previous else { return }
            self.time = now
            self.duration = self.mediaPlayer.media?.length.intValue ?? 0
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

/// Picks the audio track and subtitle track to play, listing whatever VLCKit reports for the current media
/// (subtitle options already include a "Disabled" entry from VLCKit itself).
struct TrackPickerSheet: View {
    @ObservedObject var player: VlcPlayerController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Âm thanh") {
                    ForEach(player.audioTrackOptions) { option in
                        Button {
                            player.currentAudioTrack = option.id
                        } label: {
                            HStack {
                                Text(option.name)
                                Spacer()
                                if player.currentAudioTrack == option.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                Section("Phụ đề") {
                    ForEach(player.subtitleTrackOptions) { option in
                        Button {
                            player.currentSubtitleTrack = option.id
                        } label: {
                            HStack {
                                Text(option.name)
                                Spacer()
                                if player.currentSubtitleTrack == option.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Âm thanh & Phụ đề")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
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
    var tint: Color = .white
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
                                    .foregroundStyle(index == queue.index ? Color.accentColor : .primary)
                                if item.sizeBytes > 0 {
                                    Text(item.sizeLabel).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if index == queue.index {
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor)
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
