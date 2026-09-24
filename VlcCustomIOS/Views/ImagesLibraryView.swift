import SwiftUI

/// "Ảnh" tab: pictures found in the local folder (grid) plus SMB folder browsing (grid of folders + pictures), each
/// tap opening a full-screen, zoomable, swipeable viewer with an optional slideshow — the iOS equivalent of the
/// Android app's image viewer.
struct ImagesLibraryView: View {
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
                    LocalImageGrid()
                } else {
                    SmbImageBrowser()
                }
            }
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

private struct SmbImageBrowser: View {
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
    @State private var viewerIndex: Int?
    @State private var query = ""
    @State private var sort: MediaSort = .nameAsc
    @ObservedObject private var librarySettings = LibrarySettings.shared
    private var gridColumns: [GridItem] { [GridItem(.adaptive(minimum: librarySettings.thumbnailSize.gridCell), spacing: 4)] }

    private var displayedEntries: [SmbEntry] {
        let base = query.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return sort.apply(base)
    }

    private var images: [SmbEntry] { displayedEntries.filter(\.isImage) }

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
            grid
        }
        .padding(.horizontal)
        .dismissesKeyboardOnTap()
        .searchable(text: $query)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { SortMenu(sort: $sort) }
        }
        .fullScreenCover(item: Binding(
            get: { viewerIndex.map { ViewerTarget(index: $0) } },
            set: { viewerIndex = $0?.index }
        )) { target in
            let items = imageItems
            ImageViewerScreen(items: items, startIndex: target.index, dataProvider: fetchFullImage, onClose: { viewerIndex = nil })
        }
        .task { savedProfiles = SmbServerStore.load() }
    }

    private var imageItems: [ImageItem] {
        guard let connection else { return [] }
        return images.map { ImageItem(name: $0.name, source: "smb://\(connection.host)/\($0.path)", sizeBytes: $0.sizeBytes, lastModified: $0.lastModified) }
    }

    private func fetchFullImage(_ item: ImageItem) async -> Data? {
        guard let (host, path) = SmbUri.parse(item.source) else { return nil }
        return await SmbImageLoader.data(host: host, path: path, fallbackWidth: 2560)
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
    private var grid: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 48)
        } else if connection != nil && entries.isEmpty {
            ContentUnavailableFallback(title: "Trống", message: "Thư mục này không có thư mục con hay ảnh nào.")
        } else if librarySettings.viewMode == .list {
            List(displayedEntries) { entry in
                Button { open(entry) } label: {
                    HStack(spacing: 12) {
                        if entry.isDirectory {
                            FolderThumbnailView(size: librarySettings.thumbnailSize.rowHeight)
                        } else if entry.isImage, let connection {
                            ImageThumbnailCell(
                                source: "smb://\(connection.host)/\(entry.path)",
                                dataProvider: { await fetchThumbnailData(entry) }
                            )
                            .frame(width: librarySettings.thumbnailSize.rowHeight, height: librarySettings.thumbnailSize.rowHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        Text(entry.name).lineLimit(1)
                    }
                    .padding(.vertical, 4)
                }
                .disabled(!entry.isDirectory && !entry.isImage)
            }
            .listStyle(.plain)
        } else {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 4) {
                    ForEach(displayedEntries) { entry in
                        Button { open(entry) } label: {
                            if entry.isDirectory {
                                VStack {
                                    Image(systemName: "folder.fill").font(.system(size: 32))
                                    Text(entry.name).font(.caption2).lineLimit(1)
                                }
                                .frame(height: librarySettings.thumbnailSize.gridCell)
                                .frame(maxWidth: .infinity)
                                .background(Color.secondary.opacity(0.1))
                            } else if entry.isImage, let connection {
                                ImageThumbnailCell(
                                    source: "smb://\(connection.host)/\(entry.path)",
                                    dataProvider: { await fetchThumbnailData(entry) }
                                )
                                .frame(height: librarySettings.thumbnailSize.gridCell)
                            }
                        }
                        .disabled(!entry.isDirectory && !entry.isImage)
                    }
                }
                .padding(4)
            }
        }
    }

    private func fetchThumbnailData(_ entry: SmbEntry) async -> Data? {
        guard let connection else { return nil }
        return await SmbImageLoader.data(host: connection.host, path: entry.path, fallbackWidth: 480)
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
        guard entry.isImage else { return }
        viewerIndex = images.firstIndex(of: entry)
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
            Color.black.ignoresSafeArea()
            if items.isEmpty {
                Text("Không có ảnh").foregroundStyle(.white)
            } else {
                TabView(selection: $index) {
                    ForEach(items.indices, id: \.self) { i in
                        ZoomableImage(item: items[i], dataProvider: dataProvider).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .onChange(of: index) { newIndex in prefetch(around: newIndex) }
                .onAppear { prefetch(around: index) }
            }

            VStack {
                HStack {
                    Button { onClose() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
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
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            guard slideshow, !items.isEmpty else { return }
            index = (index + 1) % items.count
        }
    }
}

private struct ZoomableImage: View {
    let item: ImageItem
    let dataProvider: (ImageItem) async -> Data?
    @State private var image: UIImage?
    @State private var placeholder: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in scale = max(1, lastScale * value) }
                            .onEnded { _ in
                                lastScale = scale
                                if scale <= 1 { withAnimation { offset = .zero; lastOffset = .zero } }
                            }
                    )
                    // Panning only exists while zoomed in. At 1x the drag gesture is switched off entirely
                    // (`including: .none`) — merely ignoring it still swallowed the swipe, so the pager behind could
                    // never move to the next picture.
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                offset = CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height)
                            }
                            .onEnded { _ in lastOffset = offset },
                        including: scale > 1 ? .all : .none
                    )
                    .onTapGesture(count: 2) {
                        withAnimation { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }
                    }
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
