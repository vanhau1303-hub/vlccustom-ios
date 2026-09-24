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
    @State private var viewer: ImageViewerTarget?
    @State private var query = ""
    /// Shared with Yêu thích folders and remembered across launches.
    @AppStorage("smb_sort") private var sort: MediaSort = .nameAsc
    @State private var addingToPlaylist: SmbEntry?
    @State private var playlists: [Playlist] = []
    @ObservedObject private var librarySettings = LibrarySettings.shared
    @State private var showScan = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                if connection == nil {
                    Group {
                        connectForm
                        if !savedProfiles.isEmpty { savedServersRow }
                        if let status { Text(status).foregroundStyle(.red).font(.footnote) }
                    }
                    .padding(.horizontal)
                } else {
                    HStack(spacing: 8) {
                        // Back = up one folder; only from the list of shares does it leave the server.
                        Button { path.isEmpty ? disconnect() : goUp() } label: {
                            Image(systemName: "chevron.backward").font(.body.weight(.semibold)).frame(width: 36, height: 36)
                        }
                        breadcrumbs
                        if !path.isEmpty {
                            Button {
                                FavoritesStore.toggle(host: host, path: path, title: (path as NSString).lastPathComponent)
                            } label: {
                                Image(systemName: FavoritesStore.isFavorite(host: host, path: path) ? "star.fill" : "star")
                                    .frame(width: 36, height: 36)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                list
            }
            // Pinned to the top — a VStack in a NavigationStack is otherwise centred vertically, which left the
            // connect form floating mid-screen.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Swipe in from the left edge = the back button: up one folder, or off the server from the share list.
            .edgeSwipeBack(enabled: connection != nil) { path.isEmpty ? disconnect() : goUp() }
            .dismissesKeyboardOnTap()
            .navigationTitle("Mạng")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { ThumbnailSizeMenu() }
                ToolbarItem(placement: .primaryAction) { SortMenu(sort: $sort) }
            }
            .fullScreenCover(item: $playing) { _ in
                PlayerScreen(onClose: { playing = nil })
            }
            .fullScreenCover(item: $viewer) { target in
                ImageViewerScreen(items: target.items, startIndex: target.index, dataProvider: SmbImageLoader.viewerData, onClose: { viewer = nil })
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

    /// Tappable path: server › share › folder › … — tapping a segment jumps straight to that folder.
    private var breadcrumbs: some View {
        let parts = path.split(separator: "/").map(String.init)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    crumb(host, target: "", isLast: parts.isEmpty).id(0)
                    ForEach(parts.indices, id: \.self) { i in
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        crumb(parts[i], target: parts[0...i].joined(separator: "/"), isLast: i == parts.count - 1).id(i + 1)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: path) { _ in
                withAnimation { proxy.scrollTo(parts.count, anchor: .trailing) }
            }
        }
    }

    private func crumb(_ title: String, target: String, isLast: Bool) -> some View {
        Button {
            guard !isLast else { return }
            path = target
            Task { await load() }
        } label: {
            Text(title)
                .font(.footnote.weight(isLast ? .semibold : .regular))
                .foregroundStyle(isLast ? Color.primary : Color.accentColor)
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Capsule().fill(isLast ? Color.secondary.opacity(0.15) : Color.accentColor.opacity(0.1)))
        }
        .buttonStyle(.plain)
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
            ContentUnavailableFallback(title: "Trống", message: "Thư mục này trống.")
        } else if let connection {
            SmbFolderContent(host: connection.host, entries: displayedEntries, onOpen: open, onAddToPlaylist: { addingToPlaylist = $0 })
        }
    }

    private var displayedEntries: [SmbEntry] {
        let base = query.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
        // Folders always on top (like Yêu thích); the chosen sort applies within folders and within files.
        return sort.apply(base.filter(\.isDirectory)) + sort.apply(base.filter { !$0.isDirectory })
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
        guard let connection else { return }
        switch SmbOpener.open(entry, siblings: displayedEntries, host: connection.host, label: "SMB: \(connection.host)/\(path)") {
        case .folder(let newPath):
            path = newPath
            Task { await load() }
        case .video:
            playing = entry
        case .images(let items, let index):
            viewer = ImageViewerTarget(items: items, index: index)
        case .audio, .none:
            break
        }
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
