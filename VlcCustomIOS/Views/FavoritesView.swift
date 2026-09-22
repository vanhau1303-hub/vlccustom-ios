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
    @ObservedObject private var librarySettings = LibrarySettings.shared

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Đang kết nối…").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 48)
                } else if let status {
                    ContentUnavailableFallback(title: "Không kết nối được", message: status)
                } else if entries.isEmpty {
                    ContentUnavailableFallback(title: "Trống", message: "Thư mục này không có thư mục con hay video nào.")
                } else if librarySettings.viewMode == .grid {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: librarySettings.thumbnailSize.gridCell), spacing: 8)], spacing: 12) {
                            ForEach(entries) { entry in
                                Button { open(entry) } label: {
                                    if entry.isDirectory {
                                        FolderGridCell(name: entry.name, cellWidth: librarySettings.thumbnailSize.gridCell)
                                    } else if let connection {
                                        VideoGridCell(source: "smb://\(connection.host)/\(entry.path)", name: entry.name, cellWidth: librarySettings.thumbnailSize.gridCell)
                                    }
                                }
                                .disabled(!entry.isDirectory && !entry.isVideo)
                            }
                        }
                        .padding(12)
                    }
                } else {
                    List(entries) { entry in
                        Button { open(entry) } label: {
                            HStack(spacing: 12) {
                                if entry.isDirectory {
                                    FolderThumbnailView(size: librarySettings.thumbnailSize.rowHeight)
                                } else if let connection {
                                    VideoThumbnailView(source: "smb://\(connection.host)/\(entry.path)", size: librarySettings.thumbnailSize.rowHeight)
                                }
                                Text(entry.name).lineLimit(1)
                            }
                            .padding(.vertical, 4)
                        }
                        .disabled(!entry.isDirectory && !entry.isVideo)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(favorite.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { ThumbnailSizeMenu() }
                ToolbarItem(placement: .confirmationAction) { Button("Đóng") { dismiss() } }
            }
            .fullScreenCover(item: $playing) { _ in
                PlayerScreen(onClose: { playing = nil })
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

    private func open(_ entry: SmbEntry) {
        if entry.isDirectory {
            Task {
                loading = true
                entries = (try? await connection?.list(path: entry.path)) ?? []
                loading = false
            }
            return
        }
        guard entry.isVideo, let connection else { return }
        let videos = entries.filter(\.isVideo)
        let items = videos.map { VideoItem(name: $0.name, source: "smb://\(connection.host)/\($0.path)", sizeBytes: $0.sizeBytes, lastModified: $0.lastModified) }
        let index = videos.firstIndex(of: entry) ?? 0
        PlaybackQueue.shared.start(items, index: index, label: favorite.title)
        playing = entry
    }
}
