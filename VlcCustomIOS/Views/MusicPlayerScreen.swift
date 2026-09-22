import SwiftUI

/// Full-screen "now playing" for the music queue — audio-only, so no video surface, just artwork placeholder,
/// transport controls, shuffle and repeat (mirrors the lock-screen controls wired up in `MusicPlayer`).
struct MusicPlayerScreen: View {
    let onClose: () -> Void
    @StateObject private var queue = MusicQueue.shared
    @StateObject private var player = MusicPlayer.shared
    @State private var seeking = false
    @State private var sliderValue: Double = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "music.note")
                    .font(.system(size: 96))
                    .foregroundStyle(.secondary)
                    .frame(width: 220, height: 220)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                VStack(spacing: 4) {
                    Text(queue.current?.title ?? "").font(.title3.bold()).multilineTextAlignment(.center)
                    if let artist = queue.current?.artist, !artist.isEmpty {
                        Text(artist).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)

                VStack(spacing: 4) {
                    Slider(value: seeking ? $sliderValue : .constant(player.progress), in: 0...1, onEditingChanged: { editing in
                        seeking = editing
                        if !editing { player.seek(to: sliderValue) }
                    })
                    .onChange(of: player.progress) { new in if !seeking { sliderValue = new } }
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Đóng") { onClose() } }
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
