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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VlcVideoView(player: player).ignoresSafeArea()
                .onTapGesture { withAnimation { showControls.toggle() } }

            if showControls {
                VStack {
                    HStack {
                        Button { close() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                        Spacer()
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
        .onDisappear { player.stop() }
        .onChange(of: player.didReachEnd) { reached in if reached { playNextOrClose() } }
        .alert("Không phát được video", isPresented: $player.showError) {
            Button("Đóng", role: .cancel) {}
        } message: {
            Text("Định dạng/codec chưa được hỗ trợ, file lỗi hoặc mất kết nối mạng (nếu là video từ SMB).")
        }
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

    var progress: Double { duration > 0 ? Double(time) / Double(duration) : 0 }

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
