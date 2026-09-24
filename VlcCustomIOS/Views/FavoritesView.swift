import SwiftUI

/// "Yêu thích" tab: SMB folders starred (via the star button shown while browsing) for one-tap reconnect and jump,
/// instead of typing the host and navigating by hand every time.
struct FavoritesView: View {
    @State private var favorites: [FavoriteFolder] = []
    @State private var opening: FavoriteFolder?
    @State private var connecting = false
    @State private var status: String?

    var body: some View {
        NavigationStack {
            Group {
                if favorites.isEmpty {
                    ContentUnavailableFallback(
                        title: "Chưa có mục yêu thích",
                        message: "Nhấn biểu tượng ngôi sao khi duyệt thư mục SMB để lưu vào đây."
                    )
                } else {
                    List {
                        ForEach(favorites) { favorite in
                            Button { open(favorite) } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.15))
                                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                                    }
                                    .frame(width: 44, height: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(favorite.title).lineLimit(1)
                                        Text("\(favorite.host)/\(favorite.path)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                    if let status { Text(status).foregroundStyle(.red).font(.footnote).padding(.horizontal) }
                }
            }
            .navigationTitle("Yêu thích")
            .sheet(item: $opening) { favorite in
                FavoriteFolderBrowser(favorite: favorite)
                    .musicPlayerHost()
            }
            .task { favorites = FavoritesStore.load() }
        }
    }

    private func open(_ favorite: FavoriteFolder) {
        opening = favorite
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets { FavoritesStore.remove(favorites[index].id) }
        favorites = FavoritesStore.load()
    }
}

/// Reconnects (using the saved login for that host, if any) and jumps straight to the starred folder.
private struct FavoriteFolderBrowser: View {
    let favorite: FavoriteFolder
    @Environment(\.dismiss) private var dismiss
    @State private var connection: SmbConnection?
    @State private var entries: [SmbEntry] = []
    @State private var status: String?
    @State private var loading = true
    @State private var playing: SmbEntry?
    @State private var viewer: ImageViewerTarget?
    /// Sub-folders opened below the starred one, so back goes up one level at a time.
    @State private var pathStack: [String] = []

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Đang kết nối…").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 48)
                } else if let status {
                    ContentUnavailableFallback(title: "Không kết nối được", message: status)
                } else if entries.isEmpty {
                    ContentUnavailableFallback(title: "Trống", message: "Thư mục này trống.")
                } else if let connection {
                    SmbFolderContent(host: connection.host, entries: entries, onOpen: open)
                }
            }
            // Swipe in from the left edge: up one folder, or close from the starred folder itself.
            .edgeSwipeBack { pathStack.isEmpty ? dismiss() : goUp() }
            .navigationTitle(pathStack.last.map { ($0 as NSString).lastPathComponent } ?? favorite.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !pathStack.isEmpty {
                        Button { goUp() } label: { Label("Lên", systemImage: "chevron.backward") }
                    }
                }
                ToolbarItem(placement: .primaryAction) { ThumbnailSizeMenu() }
                ToolbarItem(placement: .confirmationAction) { Button("Đóng") { dismiss() } }
            }
            .fullScreenCover(item: $playing) { _ in
                PlayerScreen(onClose: { playing = nil })
            }
            .fullScreenCover(item: $viewer) { target in
                ImageViewerScreen(items: target.items, startIndex: target.index, dataProvider: SmbImageLoader.viewerData, onClose: { viewer = nil })
            }
            .task { await connectAndLoad() }
        }
    }

    private func connectAndLoad() async {
        let profile = SmbServerStore.load().first { $0.host.lowercased() == favorite.host.lowercased() }
        let password = profile.map { SmbServerStore.password(for: $0.host) } ?? ""
        do {
            let conn = try await SmbRegistry.shared.connect(host: favorite.host, username: profile?.username ?? "", password: password, domain: profile?.domain ?? "")
            connection = conn
            entries = try await conn.list(path: favorite.path)
        } catch {
            status = error.localizedDescription
        }
        loading = false
    }

    private func goUp() {
        pathStack.removeLast()
        show(pathStack.last ?? favorite.path)
    }

    private func show(_ path: String) {
        guard let connection else { return }
        Task {
            loading = true
            entries = (try? await connection.list(path: path)) ?? []
            loading = false
        }
    }

    private func open(_ entry: SmbEntry) {
        guard let connection else { return }
        switch SmbOpener.open(entry, siblings: entries, host: connection.host, label: favorite.title) {
        case .folder(let path):
            pathStack.append(path)
            show(path)
        case .video:
            playing = entry
        case .images(let items, let index):
            viewer = ImageViewerTarget(items: items, index: index)
        case .audio, .none:
            break
        }
    }
}
