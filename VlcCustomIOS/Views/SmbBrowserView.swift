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
    /// `entries` filtered by the search and sorted (folders first) — computed when one of those changes, not on
    /// every redraw (a 1000-file folder was re-sorted many times a second while typing or as thumbnails arrived).
    @State private var shownEntries: [SmbEntry] = []
    @State private var status: String?
    @State private var connecting = false
    @State private var loading = false
    @State private var playing: SmbEntry?
    @State private var viewer: ImageViewerTarget?
    @State private var query = ""
    /// Results of a search through sub-folders (Search key on the keyboard); nil = just filtering this folder.
    @State private var deepResults: [SmbEntry]?
    @State private var deepSearching = false
    @State private var deepSearchTask: Task<Void, Never>?
    /// Shared with Yêu thích folders and remembered across launches.
    @AppStorage("smb_sort") private var sort: MediaSort = .nameAsc
    @State private var addingToPlaylist: SmbEntry?
    @State private var playlists: [Playlist] = []
    @ObservedObject private var librarySettings = LibrarySettings.shared
    @State private var showScan = false
    @ObservedObject private var navigator = AppNavigator.shared
    /// Reopening a folder (app start, Yêu thích): its last listing is shown while the connection comes up, instead
    /// of the login form flashing up for a moment.
    @State private var restoringHost: String?
    /// The folder on screen is the saved listing: the server did not answer this time.
    @State private var offline = false
    /// Wake-on-LAN in progress for this server ("Đang đánh thức máy chủ… 25 giây").
    @State private var wakeStatus: String?
    @State private var wakingHost: String?
    /// Saved server whose Wake-on-LAN settings are open.
    @State private var wakeSettingsHost: String?

    /// The server being browsed — connected, or being reconnected with the saved listing on screen.
    private var browsingHost: String? { connection?.host ?? restoringHost }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                if browsingHost == nil {
                    Group {
                        connectForm
                        if !savedProfiles.isEmpty { savedServersRow }
                        if let wakeStatus {
                            HStack(spacing: 8) { ProgressView(); Text(wakeStatus).font(.footnote) }
                        } else if let status {
                            Text(status).foregroundStyle(.red).font(.footnote)
                            if !host.isEmpty, WakeTargetStore.target(for: host)?.isConfigured == true {
                                Button {
                                    Task { if await wakeServer(host, manual: true) { connect() } }
                                } label: {
                                    Label("Đánh thức máy chủ rồi kết nối", systemImage: "power")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.horizontal)
                } else {
                    HStack(spacing: 8) {
                        // Back = up one folder; only from the list of shares does it leave the server.
                        Button { path.isEmpty ? disconnect() : goUp() } label: {
                            Image(systemName: "chevron.backward").font(.body.weight(.semibold))
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(.tint.opacity(0.14)))
                        }
                        breadcrumbs
                        if !path.isEmpty {
                            let starred = FavoritesStore.isFavorite(host: host, path: path)
                            Button {
                                FavoritesStore.toggle(host: host, path: path, title: (path as NSString).lastPathComponent)
                            } label: {
                                Image(systemName: starred ? "star.fill" : "star")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(starred ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.tint))
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(.tint.opacity(0.14)))
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                list
            }
            // Pinned to the top — a VStack in a NavigationStack is otherwise centred vertically, which left the
            // connect form floating mid-screen.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Swipe in from the left edge = the back button: up one folder, or off the server from the share list.
            .edgeSwipeBack(enabled: browsingHost != nil) { path.isEmpty ? disconnect() : goUp() }
            .dismissesKeyboardOnTap()
            .navigationTitle("Mạng")
            .navigationBarTitleDisplayMode(.inline)
            // Always visible (it hid under the inline title before). Typing filters this folder; the keyboard's
            // Search key also looks through every sub-folder.
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Tìm file, thư mục…")
            .onSubmit(of: .search) { searchSubfolders() }
            .onChange(of: query) { newValue in
                if newValue.isEmpty { cancelDeepSearch() }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { ThumbnailSizeMenu() }
                ToolbarItem(placement: .primaryAction) { SortMenu(sort: $sort) }
            }
            .fullScreenCover(item: $playing) { _ in
                PlayerScreen(onClose: { withoutSlide { playing = nil } })
            }
            .fullScreenCover(item: $viewer) { target in
                ImageViewerScreen(items: target.items, startIndex: target.index, dataProvider: SmbImageLoader.viewerData, onClose: { withoutSlide { viewer = nil } })
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
                if let jump = navigator.smbJump {
                    await open(jump)
                } else if connection == nil, let last = ResumeStore.folder {
                    // Relaunched (e.g. iOS closed the app in the background): back to the same folder…
                    await open(AppNavigator.SmbJump(host: last.host, path: last.path))
                    // …and the video that was playing, at its position.
                    if let video = ResumeStore.video, let connection,
                       let entry = entries.first(where: { "smb://\(connection.host)/\($0.path)" == video.source }) {
                        navigator.pendingResumeMs = (video.source, video.timeMs)
                        open(entry)
                    }
                }
            }
            .onChange(of: path) { newPath in
                if let connection { ResumeStore.saveFolder(host: connection.host, path: newPath) }
            }
            .onChange(of: navigator.smbJump) { jump in
                if let jump { Task { await open(jump) } }
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
                    crumb(host, target: "", isLast: parts.isEmpty, icon: "server.rack").id(0)
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

    private func crumb(_ title: String, target: String, isLast: Bool, icon: String? = nil) -> some View {
        Button {
            guard !isLast else { return }
            cancelDeepSearch()
            path = target
            Task { await load() }
        } label: {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.caption2) }
                Text(title).lineLimit(1)
            }
            .font(.footnote.weight(isLast ? .semibold : .medium))
            .foregroundStyle(isLast ? AnyShapeStyle(Color.white) : AnyShapeStyle(.tint))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(isLast ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.14))))
        }
        .buttonStyle(.plain)
    }

    private var connectForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.connected.to.line.below.fill")
                    .font(.title2).foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.tint))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kết nối máy chủ").font(.headline)
                    Text("Thư mục chia sẻ SMB trong mạng nhà").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showScan = true } label: {
                    Label("Tìm", systemImage: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.bordered)
            }
            field("Máy chủ (IP hoặc tên)", text: $host, icon: "server.rack")
            HStack(spacing: 8) {
                field("Tài khoản", text: $username, icon: "person.fill")
                field("Mật khẩu", text: $password, icon: "lock.fill", secure: true)
            }
            field("Domain (tuỳ chọn)", text: $domain, icon: "building.2.fill")
            Button { connect() } label: {
                HStack {
                    if connecting { ProgressView().tint(.white) }
                    Text(connecting ? "Đang kết nối…" : "Kết nối").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(connecting || host.isEmpty)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .padding(.top, 8)
        .sheet(isPresented: Binding(get: { wakeSettingsHost != nil }, set: { if !$0 { wakeSettingsHost = nil } })) {
            if let wakeHost = wakeSettingsHost {
                NavigationStack {
                    WakeOnLanView(host: wakeHost)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Xong") { wakeSettingsHost = nil } }
                        }
                }
            }
        }
        .sheet(isPresented: $showScan) {
            NetworkScanSheet(onSelect: { ip in host = ip })
        }
    }

    private func field(_ title: String, text: Binding<String>, icon: String, secure: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.footnote).foregroundStyle(.secondary).frame(width: 18)
            Group {
                if secure {
                    SecureField(title, text: text)
                } else {
                    TextField(title, text: text).autocorrectionDisabled().textInputAutocapitalization(.never)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemGroupedBackground)))
    }

    private var savedServersRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Máy chủ đã lưu").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(savedProfiles) { profile in
                        Button {
                            host = profile.host
                            username = profile.username
                            domain = profile.domain
                            password = SmbServerStore.password(for: profile.host)
                            connect()
                        } label: {
                            Label(profile.host, systemImage: "server.rack")
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(Capsule().fill(.tint.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .contextMenu {
                            Button { wakeSettingsHost = profile.host } label: {
                                Label("Wake-on-LAN…", systemImage: "power")
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var list: some View {
        if let wakeStatus, browsingHost != nil {
            HStack(spacing: 8) { ProgressView(); Text(wakeStatus).font(.footnote).foregroundStyle(.secondary) }
                .padding(.horizontal)
        } else if offline, let offlineHost = browsingHost,
                  WakeTargetStore.target(for: offlineHost)?.isConfigured == true {
            Button {
                Task { if await wakeServer(offlineHost, manual: true) { await load(force: true) } }
            } label: {
                Label("Đánh thức máy chủ", systemImage: "power").font(.footnote.weight(.semibold))
            }
            .padding(.horizontal)
        }
        if offline, browsingHost != nil {
            HStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                Text("Chưa kết nối được máy chủ — đang hiện danh sách đã lưu.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Thử lại") { Task { await load(force: true) } }.font(.footnote.weight(.semibold))
            }
            .padding(.horizontal)
        }
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 48)
        } else if browsingHost != nil && entries.isEmpty {
            ContentUnavailableFallback(title: "Trống", message: "Thư mục này trống.")
        } else if let host = browsingHost, let deepResults {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if deepSearching { ProgressView().scaleEffect(0.8) }
                    Text(deepSearching ? "Đang tìm trong các thư mục con… (\(deepResults.count) kết quả)"
                                       : "\(deepResults.count) kết quả cho \"\(query)\" (gồm thư mục con)")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Đóng") { cancelDeepSearch(); query = "" }.font(.footnote)
                }
                .padding(.horizontal)
                SmbFolderContent(host: host, entries: sortedGroups(deepResults), onOpen: open,
                                 onAddToPlaylist: { addingToPlaylist = $0 }, showsParentPath: true)
            }
        } else if let host = browsingHost {
            SmbFolderContent(host: host, entries: shownEntries, onOpen: open, onAddToPlaylist: { addingToPlaylist = $0 })
                // Pull down to read the folder again over SMB.
                .refreshable { await load(force: true) }
                .onAppear { recomputeShown() }
                .onChange(of: entries) { _ in recomputeShown() }
                .onChange(of: query) { _ in recomputeShown() }
                .onChange(of: sort) { _ in recomputeShown() }
        }
    }

    private func recomputeShown() {
        let next = displayedEntries
        if next != shownEntries { shownEntries = next }
    }

    private func sortedGroups(_ list: [SmbEntry]) -> [SmbEntry] {
        sort.apply(list.filter(\.isDirectory)) + sort.apply(list.filter { !$0.isDirectory })
    }

    /// Breadth-first through the sub-folders of the current folder (bounded, so a huge share cannot run forever),
    /// collecting every file/folder whose name contains the query; results show up as they are found.
    private func searchSubfolders() {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, let connection else { return }
        cancelDeepSearch()
        deepResults = []
        deepSearching = true
        let root = path
        deepSearchTask = Task {
            var queue: [(path: String, depth: Int)] = [(root, 0)]
            var visited = 0
            while !queue.isEmpty, !Task.isCancelled, visited < 400, (deepResults?.count ?? 0) < 1000 {
                // Four folders read at once (one at a time spent most of the search waiting on round trips).
                let batch = Array(queue.prefix(4))
                queue.removeFirst(batch.count)
                visited += batch.count
                let listed = await withTaskGroup(of: (Int, [SmbEntry]?).self) { group -> [(Int, [SmbEntry]?)] in
                    for (i, folder) in batch.enumerated() {
                        group.addTask { (i, try? await connection.list(path: folder.path)) }
                    }
                    var out: [(Int, [SmbEntry]?)] = []
                    for await result in group { out.append(result) }
                    return out.sorted { $0.0 < $1.0 }
                }
                if Task.isCancelled { break }
                for (i, items) in listed {
                    guard let items else { continue }
                    let hits = items.filter { $0.name.localizedCaseInsensitiveContains(term) }
                    if !hits.isEmpty { deepResults?.append(contentsOf: hits) }
                    if batch[i].depth < 8 {
                        queue.append(contentsOf: items.filter(\.isDirectory).map { ($0.path, batch[i].depth + 1) })
                    }
                }
            }
            if !Task.isCancelled { deepSearching = false }
        }
    }

    private func cancelDeepSearch() {
        deepSearchTask?.cancel()
        deepSearchTask = nil
        deepResults = nil
        deepSearching = false
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
            // Set up for Wake-on-LAN and not answering: wake it first rather than after a long SMB timeout.
            var woke = false
            if WakeTargetStore.autoTarget(for: host) != nil,
               !(await WakeOnLan.portOpen(host: host, port: 445, within: 3)) {
                woke = true
                _ = await wakeServer(host)
            }
            do {
                let conn = try await SmbRegistry.shared.connect(host: host, username: username, password: password, domain: domain)
                restoringHost = nil
                offline = false
                connection = conn
                ResumeStore.saveFolder(host: conn.host, path: "")
                SmbServerStore.addOrUpdate(SmbServerProfile(host: host, username: username, domain: domain), password: password)
                savedProfiles = SmbServerStore.load()
                path = ""
                await load()
            } catch {
                status = error.localizedDescription
                // Asleep or off: wake it (when set up) and try once more.
                let target = host
                if !woke, await wakeServer(target) {
                    connecting = false
                    connect()
                    return
                }
            }
            connecting = false
        }
    }

    /// The server does not answer: wake it when Wake-on-LAN is set up (automatic waking on, or `manual`), unless it
    /// is actually up (a wrong password is not fixed by waking), then wait for it. True once it answers on SMB.
    private func wakeServer(_ host: String, manual: Bool = false) async -> Bool {
        guard wakingHost == nil,
              let target = manual ? WakeTargetStore.target(for: host) : WakeTargetStore.autoTarget(for: host),
              target.isConfigured else { return false }
        if !manual, await WakeOnLan.portOpen(host: host, port: 445, within: 2) { return false }
        wakingHost = host
        wakeStatus = "Máy chủ không trả lời — đang gửi lệnh đánh thức…"
        _ = await WakeOnLan.wake(target)
        let up = await WakeOnLan.waitForSmb(host: host, timeout: 120) { seconds in
            wakeStatus = "Đang đánh thức máy chủ… \(seconds) giây (máy khởi động có thể mất 1–2 phút)"
        }
        PlaybackDiagnostics.append("wol: \(host) \(up ? "answers on SMB" : "still not answering after 2 min")")
        wakingHost = nil
        wakeStatus = nil
        if up { status = nil }
        return up
    }

    /// A folder shortcut from Yêu thích: connect (reusing the live connection or the saved login) and show it here.
    private func open(_ jump: AppNavigator.SmbJump) async {
        navigator.smbJump = nil
        host = jump.host
        if let profile = SmbServerStore.load().first(where: { $0.host.lowercased() == jump.host.lowercased() }) {
            username = profile.username
            domain = profile.domain
            password = SmbServerStore.password(for: profile.host)
        }
        status = nil
        query = ""
        cancelDeepSearch()
        // The folder's last listing on screen at once (thumbnails come from the disk cache), connection meanwhile.
        if connection?.host.lowercased() != jump.host.lowercased() {
            connection = nil
            restoringHost = jump.host
        }
        path = jump.path
        if let cached = await SmbListingCache.get(host: jump.host, path: jump.path) {
            entries = cached
            recomputeShown()
        } else {
            entries = []
        }
        // Set up for Wake-on-LAN and not answering: wake it now rather than after a long SMB timeout.
        if WakeTargetStore.autoTarget(for: jump.host) != nil,
           !(await WakeOnLan.portOpen(host: jump.host, port: 445, within: 3)) {
            _ = await wakeServer(jump.host)
        }
        connecting = true
        let conn = await SmbRegistry.shared.getOrReconnect(jump.host)
        connecting = false
        guard let conn else {
            restoringHost = nil
            connection = nil
            entries = []
            status = "Không kết nối được \(jump.host). Kiểm tra máy tính đang bật và cùng mạng Wi-Fi."
            return
        }
        connection = conn
        restoringHost = nil
        ResumeStore.saveFolder(host: conn.host, path: jump.path)
        await load()
    }

    /// Shows the folder's last listing at once (`SmbListingCache`), then the fresh one read over SMB replaces it if
    /// anything changed. `force`: pull-to-refresh — wait for the fresh listing.
    private func load(force: Bool = false) async {
        guard let connection else {
            // Still reconnecting (moved to another folder meanwhile): its saved listing, if there is one.
            if let host = restoringHost {
                let folder = path
                let cached = await SmbListingCache.get(host: host, path: folder)
                if folder == path {
                    entries = cached ?? []
                    recomputeShown()
                }
            }
            return
        }
        let host = connection.host
        let folder = path
        if !force, let cached = await SmbListingCache.get(host: host, path: folder), folder == path {
            entries = cached
            recomputeShown()
            status = nil
            loading = false
        } else if !force {
            loading = true
        }
        do {
            let fresh = try await connection.list(path: folder)
            guard folder == path else { return } // went elsewhere meanwhile
            if fresh != entries { entries = fresh }
            recomputeShown()
            status = nil
            offline = false
            SmbListingCache.put(host: host, path: folder, entries: fresh)
            // Reached: fill its Wake-on-LAN settings (MAC, LAN address, DDNS) by itself, once per launch.
            WakeAutoFill.learn(host: host, username: connection.username)
        } catch {
            guard folder == path else { return }
            // Asleep or off: wake it (when set up), then read the folder again.
            if !force, await wakeServer(host) {
                if folder == path { await load(force: true) }
                return
            }
            guard folder == path else { return }
            if entries.isEmpty {
                // Nothing saved to show: back to the login form with the reason.
                status = error.localizedDescription
                if !force {
                    self.connection = nil
                    restoringHost = nil
                }
            } else {
                offline = true
            }
        }
        if folder == path { loading = false }
    }

    private func open(_ entry: SmbEntry) {
        guard let host = browsingHost else { return }
        let siblings = deepResults.map(sortedGroups) ?? shownEntries
        switch SmbOpener.open(entry, siblings: siblings, host: host, label: "SMB: \(host)/\(path)") {
        case .folder(let newPath):
            cancelDeepSearch()
            query = ""
            path = newPath
            Task { await load() }
        case .video:
            withoutSlide { playing = entry }
        case .images(let items, let index):
            withoutSlide { viewer = ImageViewerTarget(items: items, index: index) }
        case .audio, .none:
            break
        }
    }

    private func goUp() {
        cancelDeepSearch()
        if let slash = path.lastIndex(of: "/") {
            path = String(path[path.startIndex..<slash])
        } else {
            path = ""
        }
        Task { await load() }
    }

    private func disconnect() {
        ResumeStore.saveFolder(host: nil, path: "")
        cancelDeepSearch()
        restoringHost = nil
        offline = false
        connection = nil
        entries = []
        path = ""
        status = nil
    }
}
