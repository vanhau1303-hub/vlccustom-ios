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
    @ObservedObject private var librarySettings = LibrarySettings.shared
    private var gridColumns: [GridItem] { [GridItem(.adaptive(minimum: librarySettings.thumbnailSize.gridCell), spacing: 4)] }

    var body: some View {
        Group {
            if loading {
                ProgressView("Đang quét…")
            } else if images.isEmpty {
                ContentUnavailableFallback(
                    title: "Chưa có ảnh",
                    message: "Ảnh trong thư mục đã chọn ở tab Video sẽ tự hiện ở đây."
                )
            } else if librarySettings.viewMode == .list {
                List(images.indices, id: \.self) { i in
                    Button { viewerIndex = i } label: {
                        HStack(spacing: 12) {
                            ImageThumbnailCell(source: images[i].source, dataProvider: nil)
                                .frame(width: librarySettings.thumbnailSize.rowHeight, height: librarySettings.thumbnailSize.rowHeight)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(images[i].name).lineLimit(1)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 4) {
                        ForEach(images.indices, id: \.self) { i in
                            Button { viewerIndex = i } label: {
                                ImageThumbnailCell(source: images[i].source, dataProvider: nil)
                                    .frame(height: librarySettings.thumbnailSize.gridCell)
                            }
                        }
                    }
                    .padding(4)
                }
            }
        }
        .fullScreenCover(item: Binding(
            get: { viewerIndex.map { ViewerTarget(index: $0) } },
            set: { viewerIndex = $0?.index }
        )) { target in
            ImageViewerScreen(items: images, startIndex: target.index, dataProvider: { _ in nil }, onClose: { viewerIndex = nil })
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
    @ObservedObject private var librarySettings = LibrarySettings.shared
    private var gridColumns: [GridItem] { [GridItem(.adaptive(minimum: librarySettings.thumbnailSize.gridCell), spacing: 4)] }

    private var images: [SmbEntry] { entries.filter(\.isImage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            connectForm
            if !savedProfiles.isEmpty { savedServersRow }
            if let status { Text(status).foregroundStyle(.red).font(.footnote) }
            if connection != nil {
                HStack {
                    Text(host + (path.isEmpty ? "" : "/" + path)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if !path.isEmpty { Button("↑ Lên trên") { goUp() } }
                }
            }
            grid
        }
        .padding(.horizontal)
        .dismissesKeyboardOnTap()
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
        guard let (host, path) = SmbUri.parse(item.source), let connection = await SmbRegistry.shared.get(host) else { return nil }
        guard let size = try? await connection.fileSize(path: path), size > 0, size < 60_000_000 else { return nil }
        return try? await connection.readRange(path: path, offset: 0, count: Int(size))
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
            ProgressView()
        } else if connection != nil && entries.isEmpty {
            ContentUnavailableFallback(title: "Trống", message: "Thư mục này không có thư mục con hay ảnh nào.")
        } else if librarySettings.viewMode == .list {
            List(entries) { entry in
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
                    ForEach(entries) { entry in
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
        let size = min(entry.sizeBytes, 8_000_000)
        guard size > 0 else { return nil }
        return try? await connection.readRange(path: entry.path, offset: 0, count: Int(size))
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
                            .onEnded { _ in lastScale = scale }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                guard scale > 1 else { return }
                                offset = CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height)
                            }
                            .onEnded { _ in lastOffset = offset }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }
                    }
            } else {
                ProgressView().tint(.white)
            }
        }
        .task {
            if let data = await dataProvider(item) {
                image = UIImage(data: data)
            } else if let url = URL(string: item.source) {
                image = (try? Data(contentsOf: url)).flatMap { UIImage(data: $0) }
            }
        }
    }
}
