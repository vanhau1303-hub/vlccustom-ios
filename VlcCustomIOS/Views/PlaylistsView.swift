import SwiftUI

/// "Playlist" tab: video playlists and music playlists, each created from the "Thêm vào playlist" action in the
/// video/music library screens, played back through the matching queue (`PlaybackQueue` or `MusicQueue`).
struct PlaylistsView: View {
    @State private var mode = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    Text("Video").tag(0)
                    Text("Nhạc").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if mode == 0 {
                    PlaylistListView(store: .video, kind: .video)
                } else {
                    PlaylistListView(store: .music, kind: .music)
                }
            }
            .navigationTitle("Playlist")
        }
    }
}

enum PlaylistKind: Equatable { case video, music }

private struct PlaylistListView: View {
    let store: PlaylistStore
    let kind: PlaylistKind
    @State private var playlists: [Playlist] = []
    @State private var newName = ""
    @State private var showCreate = false
    @State private var opened: Playlist?

    var body: some View {
        Group {
            if playlists.isEmpty {
                ContentUnavailableFallback(title: "Chưa có playlist", message: "Tạo playlist rồi thêm bài từ danh sách bằng cách nhấn giữ.")
            } else {
                List {
                    ForEach(playlists) { playlist in
                        Button { opened = playlist } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12))
                                    Image(systemName: "list.bullet").foregroundStyle(Color.accentColor)
                                }
                                .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name)
                                    Text("\(playlist.items.count) mục").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button { showCreate = true } label: { Image(systemName: "plus") } }
        }
        .alert("Playlist mới", isPresented: $showCreate) {
            TextField("Tên playlist", text: $newName)
            Button("Tạo") { create() }
            Button("Huỷ", role: .cancel) { newName = "" }
        }
        .sheet(item: $opened) { playlist in
            PlaylistDetailView(store: store, kind: kind, playlistId: playlist.id, onChanged: { playlists = store.load() })
        }
        .task { playlists = store.load() }
    }

    private func create() {
        guard !newName.isEmpty else { return }
        _ = store.create(name: newName)
        newName = ""
        playlists = store.load()
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets { store.delete(playlists[index].id) }
        playlists = store.load()
    }
}

private struct PlaylistDetailView: View {
    let store: PlaylistStore
    let kind: PlaylistKind
    let playlistId: String
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var items: [PlaylistItem] = []
    @State private var name: String = ""
    @State private var playingVideo = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { item in
                    Button { play(item) } label: {
                        HStack(spacing: 12) {
                            if kind == .video {
                                VideoThumbnailView(source: item.uri, size: 44)
                            } else {
                                MusicThumbnailView(size: 44)
                            }
                            Text(item.title).lineLimit(2)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .onDelete(perform: removeItems)
            }
            .navigationTitle(name)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } }
            }
            .task { reload() }
            .fullScreenCover(isPresented: $playingVideo) {
                PlayerScreen(onClose: { playingVideo = false })
            }
        }
    }

    private func reload() {
        let playlist = store.load().first { $0.id == playlistId }
        items = playlist?.items ?? []
        name = playlist?.name ?? ""
    }

    private func removeItems(_ offsets: IndexSet) {
        for index in offsets { store.removeItem(items[index].uri, from: playlistId) }
        reload()
        onChanged()
    }

    private func play(_ item: PlaylistItem) {
        switch kind {
        case .video:
            let videoItems = items.map { VideoItem(name: $0.title, source: $0.uri, sizeBytes: 0, lastModified: .distantPast) }
            let index = items.firstIndex(of: item) ?? 0
            PlaybackQueue.shared.start(videoItems, index: index, label: name)
            playingVideo = true
        case .music:
            let audioItems = items.map { AudioItem(name: $0.title, title: $0.title, artist: "", album: "", source: $0.uri, sizeBytes: 0, lastModified: .distantPast) }
            let index = items.firstIndex(of: item) ?? 0
            MusicQueue.shared.start(audioItems, index: index, label: name)
            MusicPlayer.shared.playCurrent()
            MusicUI.shared.expand()
        }
    }
}
