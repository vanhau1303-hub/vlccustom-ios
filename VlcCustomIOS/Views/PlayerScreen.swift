import SwiftUI
import MobileVLCKit

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

    private static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VlcVideoView(player: player).ignoresSafeArea()
                .onTapGesture { withAnimation { showControls.toggle() } }

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
            .padding(.bottom, showControls ? 150 : 28)
            .allowsHitTesting(false)

            if live.running, let status = live.status {
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
                VStack {
                    HStack {
                        Button { close() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                        Spacer()
                        Button { cycleSpeed() } label: { Text(speedLabel).font(.footnote.monospacedDigit()) }
                            .buttonStyle(.bordered).tint(.white)
                        Button { player.cycleAspectRatio() } label: { Image(systemName: "aspectratio") }
                        Button { player.toggleDeinterlace() } label: {
                            Image(systemName: player.deinterlaceOn ? "tv.fill" : "tv")
                        }
                        Button { showTrackPicker = true } label: { Image(systemName: "captions.bubble") }
                        Button { showPictureControls = true } label: { Image(systemName: "slider.horizontal.3") }
                        Button { showSpeechDialog = true } label: { Image(systemName: "waveform") }
                    }
                    .padding()
                    .foregroundStyle(.white)

                    Spacer()

                    VStack(spacing: 8) {
                        Text(queue.current?.name ?? "").foregroundStyle(.white).font(.footnote).lineLimit(1)
                        HStack {
                            Text(format(player.time)).foregroundStyle(.white).font(.caption).monospacedDigit()
                            Slider(value: seeking ? $sliderValue : .constant(player.progress), in: 0...1, onEditingChanged: { editing in
                                seeking = editing
                                if !editing { player.seek(to: sliderValue) }
                            })
                            .onChange(of: player.progress) { new in if !seeking { sliderValue = new } }
                            Text(format(player.duration)).foregroundStyle(.white).font(.caption).monospacedDigit()
                        }
                        HStack(spacing: 32) {
                            Button { queue.movePrevious(); player.playCurrent() } label: { Image(systemName: "backward.end.fill") }
                                .disabled(!queue.hasPrevious)
                            Button { player.togglePlayPause() } label: {
                                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 44))
                            }
                            Button { playNextOrClose() } label: { Image(systemName: "forward.end.fill") }
                                .disabled(!queue.hasNext)
                        }
                        .foregroundStyle(.white)
                    }
                    .padding()
                    .background(.black.opacity(0.6))
                }
            }
        }
        .statusBarHidden()
        .onAppear { player.playCurrent() }
        .onDisappear { player.stop(); live.stop() }
        .onChange(of: player.didReachEnd) { reached in if reached { playNextOrClose() } }
        .alert("Không phát được video", isPresented: $player.showError) {
            Button("Đóng", role: .cancel) {}
        } message: {
            Text("Định dạng/codec chưa được hỗ trợ, file lỗi hoặc mất kết nối mạng (nếu là video từ SMB).")
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

    private var speedLabel: String { "\(player.playbackRate == 1 ? "1" : String(format: "%g", player.playbackRate))x" }

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

    /// Plays `PlaybackQueue.shared.current`: a local file directly, an SMB file through the loopback proxy.
    func playCurrent() {
        guard let item = PlaybackQueue.shared.current else { return }
        didReachEnd = false
        let url: URL
        if item.isSmb {
            let withoutScheme = item.source.dropFirst("smb://".count)
            guard let slash = withoutScheme.firstIndex(of: "/") else { return }
            let host = String(withoutScheme[withoutScheme.startIndex..<slash])
            let path = String(withoutScheme[withoutScheme.index(after: slash)...])
            guard let proxied = try? SmbHttpProxy.shared.url(host: host, path: path) else { showError = true; return }
            url = proxied
        } else {
            guard let local = URL(string: item.source) else { return }
            url = local
        }
        let media = VLCMedia(url: url)
        mediaPlayer.media = media
        mediaPlayer.play()
    }

    func togglePlayPause() {
        if mediaPlayer.isPlaying { mediaPlayer.pause() } else { mediaPlayer.play() }
    }

    func seek(to fraction: Double) {
        mediaPlayer.position = Float(fraction)
    }

    func stop() {
        mediaPlayer.stop()
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
            self.isPlaying = self.mediaPlayer.isPlaying
            switch self.mediaPlayer.state {
            case .ended: self.didReachEnd = true
            case .error: self.showError = true
            default: break
            }
        }
    }

    func mediaPlayerTimeChanged(_ notification: Notification) {
        DispatchQueue.main.async {
            self.time = self.mediaPlayer.time.intValue
            self.duration = self.mediaPlayer.media?.length.intValue ?? 0
        }
    }
}

/// Hosts VLCKit's drawable view (a plain UIView it renders video into).
struct VlcVideoView: UIViewRepresentable {
    let player: VlcPlayerController

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
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
