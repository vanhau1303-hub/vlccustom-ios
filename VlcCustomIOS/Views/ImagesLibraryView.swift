import SwiftUI

/// Cài đặt → Thư viện → Ảnh: pictures found in the local folder (grid), each tap opening a full-screen, zoomable,
/// swipeable viewer with an optional slideshow. Pictures on SMB are browsed in the Mạng tab (same viewer).
struct ImagesLibraryView: View {
    var body: some View {
        NavigationStack {
            LocalImageGrid()
                .navigationTitle("Ảnh")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { ThumbnailSizeMenu() }
                }
        }
    }
}

private struct LocalImageGrid: View {
    @State private var images: [ImageItem] = []
    @State private var loading = false
    @State private var viewerIndex: Int?
    @State private var query = ""
    @State private var sort: MediaSort = .dateDesc
    @ObservedObject private var librarySettings = LibrarySettings.shared
    private var gridColumns: [GridItem] { [GridItem(.adaptive(minimum: librarySettings.thumbnailSize.gridCell), spacing: 4)] }

    private var displayed: [ImageItem] {
        let base = query.isEmpty ? images : images.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return sort.apply(base)
    }

    var body: some View {
        Group {
            if loading {
                ProgressView("Đang quét…").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 48)
            } else if images.isEmpty {
                ContentUnavailableFallback(
                    title: "Chưa có ảnh",
                    message: "Ảnh trong thư mục đã chọn ở tab Video sẽ tự hiện ở đây."
                )
            } else if librarySettings.viewMode == .list {
                List(displayed) { image in
                    Button { viewerIndex = displayed.firstIndex(of: image) } label: {
                        HStack(spacing: 12) {
                            ImageThumbnailCell(source: image.source, dataProvider: nil)
                                .frame(width: librarySettings.thumbnailSize.rowHeight, height: librarySettings.thumbnailSize.rowHeight)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(image.name).lineLimit(1)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
                .searchable(text: $query)
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 4) {
                        ForEach(displayed) { image in
                            Button { viewerIndex = displayed.firstIndex(of: image) } label: {
                                ImageThumbnailCell(source: image.source, dataProvider: nil)
                                    .frame(height: librarySettings.thumbnailSize.gridCell)
                            }
                        }
                    }
                    .padding(4)
                }
                .searchable(text: $query)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { SortMenu(sort: $sort) }
        }
        .fullScreenCover(item: Binding(
            get: { viewerIndex.map { ViewerTarget(index: $0) } },
            set: { viewerIndex = $0?.index }
        )) { target in
            ImageViewerScreen(items: displayed, startIndex: target.index, dataProvider: { _ in nil }, onClose: { viewerIndex = nil })
        }
        .task { load() }
    }

    private func load() {
        guard let url = LocalVideoService.restoredFolder() else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = LocalVideoService.scanImages(url)
            DispatchQueue.main.async { images = found; loading = false }
        }
    }
}

private struct ViewerTarget: Identifiable { let index: Int; var id: Int { index } }

/// A single grid cell: loads (and caches, via `ThumbnailService`) a downsized thumbnail for one picture.
private struct ImageThumbnailCell: View {
    let source: String
    /// Returns the picture's raw bytes for an SMB image, or nil to read a local file URL directly.
    let dataProvider: (() async -> Data?)?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.1)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ProgressView()
            }
        }
        .clipped()
        .task {
            let data = await dataProvider?()
            image = await ThumbnailService.shared.imageThumbnail(source: source, data: data)
        }
    }
}

/// Full-screen, swipeable, pinch-to-zoom viewer with an optional slideshow.
struct ImageViewerScreen: View {
    let items: [ImageItem]
    let startIndex: Int
    /// Returns full-resolution bytes for an SMB image, or nil to read a local file URL directly.
    let dataProvider: (ImageItem) async -> Data?
    let onClose: () -> Void

    @State private var index: Int
    @State private var slideshow = false
    @State private var dragDown: CGFloat = 0

    /// Loads the next and previous pictures ahead of the swipe.
    private func prefetch(around center: Int) {
        for i in [center + 1, center - 1] where items.indices.contains(i) {
            let item = items[i]
            guard FullImageCache.image(for: item.source) == nil else { continue }
            Task(priority: .utility) { _ = await FullImageCache.load(item, dataProvider: dataProvider) }
        }
    }

    init(items: [ImageItem], startIndex: Int, dataProvider: @escaping (ImageItem) async -> Data?, onClose: @escaping () -> Void) {
        self.items = items
        self.startIndex = startIndex
        self.dataProvider = dataProvider
        self.onClose = onClose
        _index = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(0.7, Double(dragDown) / 400)).ignoresSafeArea()
            if items.isEmpty {
                Text("Không có ảnh").foregroundStyle(.white)
            } else {
                TabView(selection: $index) {
                    ForEach(items.indices, id: \.self) { i in
                        ZoomableImage(item: items[i], dataProvider: dataProvider,
                                      onDismissDrag: { dragDown = $0 }, onDismiss: onClose).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                // Pull-down-to-close is handled by the picture's own scroll view (it moves the picture natively);
                // here only the background fades with it.
                .onChange(of: index) { newIndex in prefetch(around: newIndex) }
                .onAppear {
                    prefetch(around: index)
                    MusicUI.shared.picturesOpened()
                }
            }

            VStack {
                HStack {
                    Button { onClose() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                        .opacity(dragDown > 0 ? 0 : 1)
                    Spacer()
                    if items.count > 1 {
                        Button { slideshow.toggle() } label: {
                            Image(systemName: slideshow ? "pause.circle.fill" : "play.circle.fill").font(.title2)
                        }
                    }
                }
                .padding()
                .foregroundStyle(.white)
                Spacer()
                if !items.isEmpty {
                    Text(items[index].name).foregroundStyle(.white).font(.footnote).padding(.bottom)
                }
            }
        }
        .statusBarHidden()
        .fadeInOnAppear()
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            guard slideshow, !items.isEmpty else { return }
            index = (index + 1) % items.count
        }
    }
}

private struct ZoomableImage: View {
    let item: ImageItem
    let dataProvider: (ImageItem) async -> Data?
    let onDismissDrag: (CGFloat) -> Void
    let onDismiss: () -> Void
    @State private var image: UIImage?
    @State private var placeholder: UIImage?

    var body: some View {
        Group {
            if let image {
                // iOS's own zooming scroll view (pinch, double-tap, momentum, pull down to close).
                ZoomingImageView(image: image, onDismissDrag: onDismissDrag, onDismiss: onDismiss)
                    .ignoresSafeArea()
            } else if let placeholder {
                // The grid thumbnail, shown instantly while the full picture loads.
                Image(uiImage: placeholder).resizable().scaledToFit()
                    .overlay(alignment: .bottomTrailing) { ProgressView().tint(.white).padding() }
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) {
            if let cached = FullImageCache.image(for: item.source) { image = cached; return }
            placeholder = await ThumbnailService.shared.cachedThumbnail(source: item.source)
            image = await FullImageCache.load(item, dataProvider: dataProvider)
        }
    }
}

/// Screen-sized decoded pictures for the viewer: loaded and decoded off the main thread (decoding on it is what made
/// swiping stutter), kept for a few pages so swiping back is instant, and prefetched for the neighbours.
enum FullImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        cache.totalCostLimit = 160 * 1024 * 1024
        return cache
    }()

    static func clear() { cache.removeAllObjects() }

    static func image(for source: String) -> UIImage? {
        cache.object(forKey: source as NSString)
    }

    static func load(_ item: ImageItem, dataProvider: @escaping (ImageItem) async -> Data?) async -> UIImage? {
        if let cached = image(for: item.source) { return cached }
        let data: Data?
        if let provided = await dataProvider(item) {
            data = provided
        } else if let url = URL(string: item.source) {
            data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
        } else {
            data = nil
        }
        guard let data else { return nil }
        // About screen size: a full-size decode of a big photo is ~200MB.
        let decoded = await Task.detached(priority: .userInitiated) { ThumbnailService.downsample(data, maxDimension: 2560) }.value
        if let decoded {
            let cost = Int(decoded.size.width * decoded.size.height * decoded.scale * decoded.scale * 4)
            cache.setObject(decoded, forKey: item.source as NSString, cost: cost)
        }
        return decoded
    }
}
