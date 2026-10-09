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
                    GeometryReader { geo in
                        let columns = geo.size.width > geo.size.height ? 4 : 2
                        let spacing: CGFloat = 12
                        let width = max(80, floor((geo.size.width - 32 - spacing * CGFloat(columns - 1)) / CGFloat(columns)))
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: spacing), count: columns), spacing: 18) {
                                ForEach(favorites) { favorite in
                                    Button { open(favorite) } label: { card(favorite, width: width) }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button(role: .destructive) { remove(favorite) } label: {
                                                Label("Bỏ khỏi Yêu thích", systemImage: "star.slash")
                                            }
                                        }
                                }
                            }
                            .padding(16)
                        }
                    }
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

    /// A card: the folder's mosaic / the file's thumbnail, a kind badge, the name and where it is.
    private func card(_ favorite: FavoriteFolder, width: CGFloat) -> some View {
        let height = width * 9 / 16
        let item = entry(for: favorite)
        return VStack(alignment: .leading, spacing: 6) {
            Group {
                switch item.kind {
                case .folder: SmbFolderThumbnailView(host: favorite.host, path: favorite.path, width: width, height: height)
                case .video: VideoThumbnailView(source: "smb://\(favorite.host)/\(favorite.path)", size: height)
                case .image: SmbImageThumbnailView(host: favorite.host, path: favorite.path, width: width, height: height)
                case .audio: AudioCoverView(source: "smb://\(favorite.host)/\(favorite.path)", size: height, width: width)
                case .other: SmbEntryThumbnail(entry: item, host: favorite.host, size: height).frame(width: width)
                }
            }
            .overlay(alignment: .topLeading) {
                Image(systemName: favorite.isFileShortcut ? "play.fill" : "folder.fill")
                    .font(.caption.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.tint))
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            // The shadow comes from a plain shape behind the card: shadowing the picture itself rendered every
            // card off-screen again on each frame of scrolling.
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .shadow(color: .black.opacity(0.16), radius: 6, x: 0, y: 3)
            )
            Text(favorite.title).font(.footnote.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
                .padding(.horizontal, 2)
            Text("\(favorite.host)/\((favorite.path as NSString).deletingLastPathComponent)")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                .padding(.horizontal, 2)
        }
        .frame(width: width, alignment: .leading)
    }

    private func remove(_ favorite: FavoriteFolder) {
        FavoritesStore.remove(favorite.id)
        withAnimation { favorites = FavoritesStore.load() }
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

}

/// Cross-tab navigation: which tab is showing, and a pending "open this SMB folder" request for the Mạng tab.
final class AppNavigator: ObservableObject {
    static let shared = AppNavigator()

    struct SmbJump: Equatable {
        let id = UUID()
        let host: String
        let path: String
    }

    @Published var selectedTab = ProcessInfo.processInfo.environment["DEMO_TAB"].flatMap(Int.init) ?? ResumeStore.tab ?? 1 {
        didSet { ResumeStore.tab = selectedTab }
    }
    /// Position to reopen the next video at (restored after iOS closed the app while it was playing).
    var pendingResumeMs: (source: String, ms: Int32)?
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
