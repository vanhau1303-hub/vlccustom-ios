import SwiftUI

/// The collapsed music player, pinned at the bottom whenever a song is loaded so music keeps playing (and stays
/// reachable) on every screen: cover + title (tap to expand), play/pause, next, and a seek bar with elapsed/total
/// time — tap anywhere on it to jump there.
struct NowPlayingBar: View {
    @ObservedObject private var queue = MusicQueue.shared
    @ObservedObject private var player = MusicPlayer.shared
    let onTap: () -> Void
    @State private var seeking = false
    @State private var seekValue: Double = 0

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    if let artwork = player.artwork {
                        Image(uiImage: artwork).resizable().scaledToFill()
                            .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "music.note").font(.title3).foregroundStyle(.secondary)
                            .frame(width: 40, height: 40)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(queue.current?.title ?? "").font(.subheadline.weight(.medium)).lineLimit(1)
                        if let artist = queue.current?.artist, !artist.isEmpty {
                            Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                        .frame(width: 40, height: 40)
                }
                Button { player.playNext() } label: {
                    Image(systemName: "forward.fill").font(.title3).frame(width: 36, height: 40)
                }
                .disabled(!queue.hasNext)
            }
            HStack(spacing: 8) {
                Text(format(seeking ? Int32(seekValue * Double(player.duration)) : player.time))
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                SeekBar(progress: seeking ? seekValue : player.progress,
                        tint: .accentColor, track: Color.secondary.opacity(0.3),
                        onScrub: { fraction in
                            seeking = true
                            seekValue = fraction
                        },
                        onCommit: { fraction in
                            seekValue = fraction
                            player.seek(to: fraction)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { seeking = false }
                        })
                Text(format(player.duration)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.thinMaterial)
        .foregroundStyle(.primary)
    }

    private func format(_ ms: Int32) -> String {
        let total = max(0, Int(ms) / 1000)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
