import SwiftUI

/// Full-screen "now playing" for the music queue — audio-only, so no video surface, just artwork placeholder,
/// transport controls, shuffle and repeat (mirrors the lock-screen controls wired up in `MusicPlayer`).
struct MusicPlayerScreen: View {
    let onClose: () -> Void
    @StateObject private var queue = MusicQueue.shared
    @StateObject private var player = MusicPlayer.shared
    @State private var seeking = false
    @State private var sliderValue: Double = 0
    @State private var dragDown: CGFloat = 0
    /// Set when a vertical drag started on the right half: it adjusts the volume instead of collapsing.
    @State private var volumeDrag: Float?
    @State private var hint: String?

    var body: some View {
        GeometryReader { geo in
            content
                // Swipe down on the left half = collapse to the mini bar (the music keeps playing);
                // swipe up/down on the right half = volume, like the video player.
                .offset(y: dragDown)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { value in
                            guard abs(value.translation.height) > abs(value.translation.width) else { return }
                            if volumeDrag == nil, value.startLocation.x > geo.size.width / 2 {
                                volumeDrag = SystemVolume.current
                            }
                            if let base = volumeDrag {
                                let newValue = min(1, max(0, base + Float(-value.translation.height / geo.size.height) * 1.5))
                                SystemVolume.set(newValue)
                                hint = "Âm lượng \(Int((newValue * 100).rounded()))%"
                            } else if value.translation.height > 0 {
                                dragDown = value.translation.height
                            }
                        }
                        .onEnded { value in
                            if volumeDrag == nil, dragDown > 120 || value.predictedEndTranslation.height > 400 {
                                onClose()
                            }
                            volumeDrag = nil
                            hint = nil
                            withAnimation(.easeOut(duration: 0.2)) { dragDown = 0 }
                        }
                )
                .overlay {
                    if let hint {
                        Text(hint)
                            .font(.headline).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Color.black.opacity(0.7))
                            .clipShape(Capsule())
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    /// Double-tap the left/right half of the artwork: back/forward 30s.
    private func handleDoubleTap(_ location: CGPoint, width: CGFloat) {
        let forward = location.x > width / 2
        player.skip(ms: forward ? 30_000 : -30_000)
        let text = forward ? "+30s" : "-30s"
        hint = text
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if hint == text { hint = nil }
        }
    }

    private var content: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Group {
                    if let artwork = player.artwork {
                        Image(uiImage: artwork).resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 96))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.secondary.opacity(0.1))
                    }
                }
                .frame(width: 280, height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(count: 2).onEnded { value in handleDoubleTap(value.location, width: 280) })
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)

                VStack(spacing: 4) {
                    Text(queue.current?.title ?? "").font(.title3.bold()).multilineTextAlignment(.center)
                    if let artist = queue.current?.artist, !artist.isEmpty {
                        Text(artist).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)

                VStack(spacing: 4) {
                    // Tap anywhere on the bar to jump there, or drag to scrub.
                    SeekBar(progress: seeking ? sliderValue : player.progress,
                            tint: .accentColor, track: Color.secondary.opacity(0.3),
                            onScrub: { fraction in
                                seeking = true
                                sliderValue = fraction
                            },
                            onCommit: { fraction in
                                sliderValue = fraction
                                player.seek(to: fraction)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { seeking = false }
                            })
                    HStack {
                        Text(format(player.time)).font(.caption).monospacedDigit()
                        Spacer()
                        Text(format(player.duration)).font(.caption).monospacedDigit()
                    }
                }
                .padding(.horizontal)

                HStack(spacing: 36) {
                    Button { queue.shuffle.toggle() } label: { Image(systemName: "shuffle") }
                        .foregroundStyle(queue.shuffle ? Color.accentColor : .primary)
                    Button { player.playPrevious() } label: { Image(systemName: "backward.end.fill").font(.title2) }
                        .disabled(!queue.hasPrevious)
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 56))
                    }
                    Button { player.playNext() } label: { Image(systemName: "forward.end.fill").font(.title2) }
                        .disabled(!queue.hasNext)
                    Button { cycleRepeat() } label: { Image(systemName: repeatIcon) }
                        .foregroundStyle(queue.repeatMode == .off ? .primary : Color.accentColor)
                }
                Spacer()
            }
            .padding()
            .edgeSwipeBack { onClose() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { onClose() } label: { Image(systemName: "chevron.down").font(.title3.weight(.semibold)) }
                }
            }
            .alert("Không phát được bài này", isPresented: $player.showError) {
                Button("Đóng", role: .cancel) {}
            }
        }
    }

    private var repeatIcon: String {
        switch queue.repeatMode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private func cycleRepeat() {
        switch queue.repeatMode {
        case .off: queue.repeatMode = .all
        case .all: queue.repeatMode = .one
        case .one: queue.repeatMode = .off
        }
    }

    private func format(_ ms: Int32) -> String {
        let total = max(0, Int(ms) / 1000)
        let m = total / 60, s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
