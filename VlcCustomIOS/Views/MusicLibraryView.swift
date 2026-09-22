import SwiftUI

/// "Nhạc" tab: songs found in the same local folder picked for videos, plus browsing SMB shares for audio files.
/// Playback goes through the dedicated `MusicPlayer`/`MusicQueue` (separate from the video player) so a song keeps
/// playing in the background while the user browses elsewhere in the app.
struct MusicLibraryView: View {
    @State private var mode = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    Text("Trên máy").tag(0)
                    Text("Mạng (SMB)").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if mode == 0 {
                    LocalAudioList()
                } else {
                    SmbAudioBrowser()
                }
            }
            .navigationTitle("Nhạc")
        }
    }
}

private struct LocalAudioList: View {
    @State private var songs: [AudioItem] = []
    @State private var loading = false
    @State private var query = ""
    @State private var sort: MediaSort = .nameAsc
    @State private var addingToPlaylist: AudioItem?
    @State private var playlists: [Playlist] = []
    @ObservedObject private var librarySettings = LibrarySettings.shared

    private var displayed: [AudioItem] {
        let base = query.isEmpty ? songs : songs.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return sort.apply(base)
    }

    var body: some View {
        Group {
            if loading {
                ProgressView("Đang quét…")
            } else if songs.isEmpty {
                ContentUnavailableFallback(
                    title: "Chưa có nhạc",
                    message: "Nhạc trong thư mục đã chọn ở tab Video sẽ tự hiện ở đây."
                )
            } else if librarySettings.viewMode == .grid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: librarySettings.thumbnailSize.gridCell), spacing: 8)], spacing: 12) {
                        ForEach(displayed) { song in
                            Button { play(song) } label: {
                                MusicGridCell(name: song.title, cellWidth: librarySettings.thumbnailSize.gridCell)
                            }
                            .contextMenu {
                                Button { addingToPlaylist = song } label: { Label("Thêm vào playlist", systemImage: "text.badge.plus") }
                            }
                        }
                    }
                    .padding(12)
                }
                .searchable(text: $query)
            } else {
                List(displayed) { song in
                    Button { play(song) } label: {
                        HStack(spacing: 12) {
                            MusicThumbnailView(size: librarySettings.thumbnailSize.rowHeight)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title).lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: song.sizeBytes, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .contextMenu {
                        Button { addingToPlaylist = song } label: { Label("Thêm vào playlist", systemImage: "text.badge.plus") }
                    }
                }
                .searchable(text: $query)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ThumbnailSizeMenu() }
            ToolbarItem(placement: .primaryAction) { SortMenu(sort: $sort) }
        }
        .confirmationDialog("Thêm vào playlist", isPresented: Binding(get: { addingToPlaylist != nil }, set: { if !$0 { addingToPlaylist = nil } }), titleVisibility: .visible) {
            ForEach(playlists) { playlist in
                Button(playlist.name) { addToPlaylist(playlist) }
            }
            Button("Tạo playlist mới") { createPlaylistAndAdd() }
            Button("Huỷ", role: .cancel) {}
        }
        .task {
            load()
            playlists = PlaylistStore.music.load()
        }
    }

    private func load() {
        guard let url = LocalVideoService.restoredFolder() else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = LocalVideoService.scanAudio(url)
            DispatchQueue.main.async { songs = found; loading = false }
        }
    }

    private func play(_ song: AudioItem) {
        MusicQueue.shared.start(displayed, index: displayed.firstIndex(of: song) ?? 0)
        MusicPlayer.shared.playCurrent()
    }

    private func addToPlaylist(_ playlist: Playlist) {
        guard let song = addingToPlaylist else { return }
        PlaylistStore.music.addItem(PlaylistItem(uri: song.source, title: song.title), to: playlist.id)
        addingToPlaylist = nil
    }

    private func createPlaylistAndAdd() {
        guard let song = addingToPlaylist else { return }
        let playlist = PlaylistStore.music.create(name: song.title)
        PlaylistStore.music.addItem(PlaylistItem(uri: song.source, title: song.title), to: playlist.id)
        playlists = PlaylistStore.music.load()
        addingToPlaylist = nil
    }
}

private struct SmbAudioBrowser: View {
    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var savedProfiles: [SmbServerProfile] = []

    @State private var connection: SmbConnection?
    @State private var path = ""
    @State private var entries: [SmbEntry] = []
    @State private var status: String?
    @State private var connecting = false
    @State private var loading = false
    @State private var query = ""
    @State private var sort: MediaSort = .nameAsc
    @ObservedObject private var librarySettings = LibrarySettings.shared

    private var displayed: [SmbEntry] {
        let base = query.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return sort.apply(base)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if connection == nil {
                connectForm
                if !savedProfiles.isEmpty { savedServersRow }
                if let status { Text(status).foregroundStyle(.red).font(.footnote) }
            } else {
                HStack {
                    Button { disconnect() } label: { Image(systemName: "chevron.backward") }
                    Text(host + (path.isEmpty ? "" : "/" + path)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if !path.isEmpty { Button("↑ Lên trên") { goUp() } }
                }
            }
            list
        }
        .padding(.horizontal)
        .dismissesKeyboardOnTap()
        .searchable(text: $query)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { ThumbnailSizeMenu() }
            ToolbarItem(placement: .primaryAction) { SortMenu(sort: $sort) }
        }
        .task { savedProfiles = SmbServerStore.load() }
    }

    private var connectForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Máy chủ (IP hoặc tên)", text: $host).textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
            HStack {
                TextField("Tài khoản", text: $username).textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                SecureField("Mật khẩu", text: $password).textFieldStyle(.roundedBorder)
            }
            HStack {
                TextField("Domain (tuỳ chọn)", text: $domain).textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button(connecting ? "Đang kết nối…" : "Kết nối") { connect() }
                    .disabled(connecting || host.isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var savedServersRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(savedProfiles) { profile in
                    Button(profile.host) {
                        host = profile.host
                        username = profile.username
                        domain = profile.domain
                        password = SmbServerStore.password(for: profile.host)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        if loading {
            ProgressView()
        } else if connection != nil && entries.isEmpty {
            ContentUnavailableFallback(title: "Trống", message: "Thư mục này không có thư mục con hay bài hát nào.")
        } else if librarySettings.viewMode == .grid {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: librarySettings.thumbnailSize.gridCell), spacing: 8)], spacing: 12) {
                    ForEach(displayed) { entry in
                        Button { open(entry) } label: {
                            if entry.isDirectory {
                                FolderGridCell(name: entry.name, cellWidth: librarySettings.thumbnailSize.gridCell)
                            } else {
                                MusicGridCell(name: entry.name, cellWidth: librarySettings.thumbnailSize.gridCell)
                            }
                        }
                        .disabled(!entry.isDirectory && !entry.isAudio)
                    }
                }
                .padding(12)
            }
        } else {
            List(displayed) { entry in
                Button { open(entry) } label: {
                    HStack(spacing: 12) {
                        if entry.isDirectory {
                            FolderThumbnailView(size: librarySettings.thumbnailSize.rowHeight)
                        } else {
                            MusicThumbnailView(size: librarySettings.thumbnailSize.rowHeight)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).lineLimit(1)
                            if !entry.isDirectory {
                                Text(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .disabled(!entry.isDirectory && !entry.isAudio)
            }
            .listStyle(.plain)
        }
    }

    private func connect() {
        connecting = true
        status = nil
        Task {
            do {
                let conn = try await SmbRegistry.shared.connect(host: host, username: username, password: password, domain: domain)
                connection = conn
                SmbServerStore.addOrUpdate(SmbServerProfile(host: host, username: username, domain: domain), password: password)
                savedProfiles = SmbServerStore.load()
                path = ""
                await load()
            } catch {
                status = error.localizedDescription
            }
            connecting = false
        }
    }

    private func load() async {
        guard let connection else { return }
        loading = true
        do {
            entries = try await connection.list(path: path)
            status = nil
        } catch {
            status = error.localizedDescription
        }
        loading = false
    }

    private func open(_ entry: SmbEntry) {
        if entry.isDirectory {
            path = entry.path
            Task { await load() }
            return
        }
        guard entry.isAudio, let connection else { return }
        let songs = displayed.filter(\.isAudio)
        let items = songs.map {
            AudioItem(name: $0.name, title: ($0.name as NSString).deletingPathExtension, artist: "", album: "",
                      source: "smb://\(connection.host)/\($0.path)", sizeBytes: $0.sizeBytes, lastModified: $0.lastModified)
        }
        let index = songs.firstIndex(of: entry) ?? 0
        MusicQueue.shared.start(items, index: index, label: "SMB: \(connection.host)/\(path)")
        MusicPlayer.shared.playCurrent()
    }

    private func goUp() {
        if let slash = path.lastIndex(of: "/") {
            path = String(path[path.startIndex..<slash])
        } else {
            path = ""
        }
        Task { await load() }
    }

    private func disconnect() {
        connection = nil
        entries = []
        path = ""
        status = nil
    }
}
