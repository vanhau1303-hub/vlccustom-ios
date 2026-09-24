import SwiftUI

/// A thin bar pinned above the tab bar whenever a song is loaded, so music keeps playing (and stays reachable) no
/// matter which tab the user is on — the iOS equivalent of Android's persistent mini player.
struct NowPlayingBar: View {
    @ObservedObject private var queue = MusicQueue.shared
    @ObservedObject private var player = MusicPlayer.shared
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                if let artwork = player.artwork {
                    Image(uiImage: artwork).resizable().scaledToFill()
                        .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "music.note").font(.title3).foregroundStyle(.secondary).frame(width: 36, height: 36)
                }
                Text(queue.current?.title ?? "").font(.subheadline).lineLimit(1)
                Spacer()
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                }
                Button { player.playNext() } label: {
                    Image(systemName: "forward.fill").font(.title3)
                }
                .disabled(!queue.hasNext)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.thinMaterial)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}
