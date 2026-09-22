import SwiftUI

/// "Mạng (SMB)" tab: connect to a server, browse folders, play a video.
struct SmbBrowserView: View {
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
    @State private var playing: SmbEntry?
    @State private var query = ""
    @State private var sort: MediaSort = .nameAsc
    @State private var addingToPlaylist: SmbEntry?
    @State private var playlists: [Playlist] = []
    @ObservedObject private var librarySettings = LibrarySettings.shared
    @State private var showScan = false

    var body: some View {
        NavigationStack {
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
                        if !path.isEmpty {
                            Button {
                                FavoritesStore.toggle(host: host, path: path, title: (path as NSString).lastPathComponent)
                            } label: {
                                Image(systemName: FavoritesStore.isFavorite(host: host, path: path) ? "star.fill" : "star")
                            }
                            Button("↑ Lên trên") { goUp() }
                        }
                    }
                }
                list
            }
            .padding(.horizontal)
            .dismissesKeyboardOnTap()
            .navigationTitle("Mạng (SMB)")
            .searchable(text: $query)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { ThumbnailSizeMenu() }
                ToolbarItem(placement: .primaryAction) { SortMenu(sort: $sort) }
            }
            .fullScreenCover(item: $playing) { _ in
                PlayerScreen(onClose: { playing = nil })
            }
            .confirmationDialog("Thêm vào playlist", isPresented: Binding(get: { addingToPlaylist != nil }, set: { if !$0 { addingToPlaylist = nil } }), titleVisibility: .visible) {
                ForEach(playlists) { playlist in
                    Button(playlist.name) { addToPlaylist(playlist) }
                }
                Button("Tạo playlist mới") { createPlaylistAndAdd() }
                Button("Huỷ", role: .cancel) {}
            }
            .task {
                savedProfiles = SmbServerStore.load()
                playlists = PlaylistStore.video.load()
            }
        }
    }

    private func addToPlaylist(_ playlist: Playlist) {
        guard let entry = addingToPlaylist, let connection else { return }
        let uri = "smb://\(connection.host)/\(entry.path)"
        PlaylistStore.video.addItem(PlaylistItem(uri: uri, title: entry.name), to: playlist.id)
        addingToPlaylist = nil
    }

    private func createPlaylistAndAdd() {
        guard let entry = addingToPlaylist, let connection else { return }
        let playlist = PlaylistStore.video.create(name: entry.name)
        let uri = "smb://\(connection.host)/\(entry.path)"
        PlaylistStore.video.addItem(PlaylistItem(uri: uri, title: entry.name), to: playlist.id)
        playlists = PlaylistStore.video.load()
        addingToPlaylist = nil
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
                Button { showScan = true } label: { Image(systemName: "network") }
                    .buttonStyle(.bordered)
                Button(connecting ? "Đang kết nối…" : "Kết nối") { connect() }
                    .disabled(connecting || host.isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .sheet(isPresented: $showScan) {
            NetworkScanSheet(onSelect: { ip in host = ip })
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
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 48)
        } else if connection != nil && entries.isEmpty {
            ContentUnavailableFallback(title: "Trống", message: "Thư mục này không có thư mục con hay video nào.")
        } else if librarySettings.viewMode == .grid {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: librarySettings.thumbnailSize.gridCell), spacing: 8)], spacing: 12) {
                    ForEach(displayedEntries) { entry in
                        Button { open(entry) } label: {
                            if entry.isDirectory {
                                FolderGridCell(name: entry.name, cellWidth: librarySettings.thumbnailSize.gridCell)
                            } else if let connection {
                                VideoGridCell(source: "smb://\(connection.host)/\(entry.path)", name: entry.name, cellWidth: librarySettings.thumbnailSize.gridCell)
                            }
                        }
                        .disabled(!entry.isDirectory && !entry.isVideo)
                        .contextMenu {
                            if entry.isVideo {
                                Button { addingToPlaylist = entry } label: { Label("Thêm vào playlist", systemImage: "text.badge.plus") }
                            }
                        }
                    }
                }
                .padding(12)
            }
        } else {
            List(displayedEntries) { entry in
                Button {
                    open(entry)
                } label: {
                    HStack(spacing: 12) {
                        if entry.isDirectory {
                            FolderThumbnailView(size: librarySettings.thumbnailSize.rowHeight)
                        } else if let connection {
                            VideoThumbnailView(source: "smb://\(connection.host)/\(entry.path)", size: librarySettings.thumbnailSize.rowHeight)
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
                .disabled(!entry.isDirectory && !entry.isVideo)
                .contextMenu {
                    if entry.isVideo {
                        Button { addingToPlaylist = entry } label: { Label("Thêm vào playlist", systemImage: "text.badge.plus") }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private var displayedEntries: [SmbEntry] {
        let base = query.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return sort.apply(base)
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
        guard entry.isVideo, let connection else { return }
        let videos = displayedEntries.filter(\.isVideo)
        let items = videos.map { VideoItem(name: $0.name, source: "smb://\(connection.host)/\($0.path)", sizeBytes: $0.sizeBytes, lastModified: $0.lastModified) }
        let index = videos.firstIndex(of: entry) ?? 0
        PlaybackQueue.shared.start(items, index: index, label: "SMB: \(connection.host)/\(path)")
        playing = entry
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
