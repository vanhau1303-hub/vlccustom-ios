import SwiftUI

/// "Yêu thích" tab: shortcuts only. A starred folder opens in the Mạng tab (same browser, breadcrumbs, back);
/// a starred file opens straight away (video player, picture viewer or music player).
struct FavoritesView: View {
    @State private var favorites: [FavoriteFolder] = []
    @State private var playing = false
    @State private var viewer: ImageViewerTarget?
    @ObservedObject private var navigator = AppNavigator.shared

    var body: some View {
        NavigationStack {
            Group {
                if favorites.isEmpty {
                    ContentUnavailableFallback(
                        title: "Chưa có mục yêu thích",
                        message: "Trong tab Mạng: bấm ngôi sao để lưu thư mục đang mở, hoặc nhấn giữ một file/thư mục → Thêm vào Yêu thích."
                    )
                } else {
                    List {
                        ForEach(favorites) { favorite in
                            Button { open(favorite) } label: { row(favorite) }
                        }
                        .onDelete(perform: delete)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Yêu thích")
            .fullScreenCover(isPresented: $playing) {
                PlayerScreen(onClose: { withoutSlide { playing = false } })
            }
            .fullScreenCover(item: $viewer) { target in
                ImageViewerScreen(items: target.items, startIndex: target.index, dataProvider: SmbImageLoader.viewerData, onClose: { withoutSlide { viewer = nil } })
            }
            .onAppear { favorites = FavoritesStore.load() }
            .onChange(of: navigator.favoritesVersion) { _ in favorites = FavoritesStore.load() }
        }
    }

    private func row(_ favorite: FavoriteFolder) -> some View {
        HStack(spacing: 12) {
            SmbEntryThumbnail(entry: entry(for: favorite), host: favorite.host, size: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(favorite.title).lineLimit(2)
                Text("\(favorite.host)/\(favorite.path)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: favorite.isFileShortcut ? "play.circle" : "arrow.turn.up.right")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func entry(for favorite: FavoriteFolder) -> SmbEntry {
        SmbEntry(name: (favorite.path as NSString).lastPathComponent, path: favorite.path,
                 isDirectory: !favorite.isFileShortcut, sizeBytes: 0, lastModified: .distantPast)
    }

    private func open(_ favorite: FavoriteFolder) {
        guard favorite.isFileShortcut else {
            navigator.openSmbFolder(host: favorite.host, path: favorite.path)
            return
        }
        let file = entry(for: favorite)
        switch SmbOpener.open(file, siblings: [file], host: favorite.host, label: favorite.title) {
        case .video: withoutSlide { playing = true }
        case .images(let items, let index): withoutSlide { viewer = ImageViewerTarget(items: items, index: index) }
        case .audio, .folder, .none: break
        }
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets { FavoritesStore.remove(favorites[index].id) }
        favorites = FavoritesStore.load()
    }
}

/// Cross-tab navigation: which tab is showing, and a pending "open this SMB folder" request for the Mạng tab.
final class AppNavigator: ObservableObject {
    static let shared = AppNavigator()

    struct SmbJump: Equatable {
        let id = UUID()
        let host: String
        let path: String
    }

    @Published var selectedTab = 1
    @Published var smbJump: SmbJump?
    /// Bumped whenever favorites change elsewhere, so the Yêu thích list reloads.
    @Published private(set) var favoritesVersion = 0

    private init() {}

    func openSmbFolder(host: String, path: String) {
        smbJump = SmbJump(host: host, path: path)
        selectedTab = 1
    }

    func favoritesChanged() {
        favoritesVersion += 1
    }
}
