import SwiftUI

/// What an SMB entry is, for picking its thumbnail and what tapping it does.
enum SmbEntryKind { case folder, video, image, audio, other }

extension SmbEntry {
    var kind: SmbEntryKind {
        if isDirectory { return .folder }
        if isVideo { return .video }
        if isImage { return .image }
        if isAudio { return .audio }
        return .other
    }
}

/// What the caller has to present after `SmbOpener.open` (folders and music are handled without a new screen).
enum SmbOpenAction {
    case folder(path: String)
    case video
    case images(items: [ImageItem], index: Int)
    case audio
    case none
}

/// One place that knows how to open any SMB entry, so the Mạng and Yêu thích screens behave the same.
enum SmbOpener {
    @MainActor
    static func open(_ entry: SmbEntry, siblings: [SmbEntry], host: String, label: String) -> SmbOpenAction {
        func source(_ e: SmbEntry) -> String { "smb://\(host)/\(e.path)" }
        switch entry.kind {
        case .folder:
            return .folder(path: entry.path)
        case .video:
            let videos = siblings.filter { $0.kind == .video }
            let items = videos.map { VideoItem(name: $0.name, source: source($0), sizeBytes: $0.sizeBytes, lastModified: $0.lastModified) }
            PlaybackQueue.shared.start(items, index: videos.firstIndex(of: entry) ?? 0, label: label)
            return .video
        case .image:
            let images = siblings.filter { $0.kind == .image }
            let items = images.map { ImageItem(name: $0.name, source: source($0), sizeBytes: $0.sizeBytes, lastModified: $0.lastModified) }
            return .images(items: items, index: images.firstIndex(of: entry) ?? 0)
        case .audio:
            let songs = siblings.filter { $0.kind == .audio }
            let items = songs.map {
                AudioItem(name: $0.name, title: ($0.name as NSString).deletingPathExtension, artist: "", album: "",
                          source: source($0), sizeBytes: $0.sizeBytes, lastModified: $0.lastModified)
            }
            MusicQueue.shared.start(items, index: songs.firstIndex(of: entry) ?? 0, label: label)
            MusicPlayer.shared.playCurrent()
            MusicUI.shared.expand()
            return .audio
        case .other:
            return .none
        }
    }
}

/// The leading thumbnail for any SMB entry, sized for a list row (`size` = row height).
struct SmbEntryThumbnail: View {
    let entry: SmbEntry
    let host: String
    let size: CGFloat

    var body: some View {
        switch entry.kind {
        case .folder: FolderThumbnailView(size: size)
        case .video: VideoThumbnailView(source: "smb://\(host)/\(entry.path)", size: size)
        case .image: SmbImageThumbnailView(host: host, path: entry.path, width: size * 16 / 9, height: size)
        case .audio: AudioCoverView(source: "smb://\(host)/\(entry.path)", size: size)
        case .other:
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1))
                Image(systemName: "doc").foregroundStyle(.secondary)
            }
            .frame(width: size, height: size)
        }
    }
}

/// Thumbnail of a picture on an SMB share (cached by `ThumbnailService`).
struct SmbImageThumbnailView: View {
    let host: String
    let path: String
    let width: CGFloat
    let height: CGFloat
    @State private var image: UIImage?
    @ObservedObject private var events = ThumbnailEvents.shared

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: "\(path)#\(events.version)") {
            image = await ThumbnailService.shared.smbImageThumbnail(source: "smb://\(host)/\(path)", host: host, path: path)
        }
    }
}

/// The folder listing (list or grid, per `LibrarySettings`) used by both the Mạng tab and a Yêu thích folder.
struct SmbFolderContent: View {
    let host: String
    let entries: [SmbEntry]
    let onOpen: (SmbEntry) -> Void
    var onAddToPlaylist: ((SmbEntry) -> Void)?
    /// Search results from sub-folders: show each entry's folder under its name.
    var showsParentPath = false
    @ObservedObject private var librarySettings = LibrarySettings.shared
    @State private var optionsEntry: SmbEntry?

    var body: some View {
        content
            .sheet(item: $optionsEntry) { entry in
                SmbEntryOptionsSheet(
                    entry: entry, host: host,
                    onOpen: { onOpen(entry) },
                    onAddToPlaylist: onAddToPlaylist.map { add in { add(entry) } }
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        if librarySettings.viewMode == .grid {
            // As big as the screen allows: 2 columns upright, 4 in landscape.
            GeometryReader { geo in
                let columns = geo.size.width > geo.size.height ? 4 : 2
                let spacing: CGFloat = 10
                let cellWidth = max(80, floor((geo.size.width - 24 - spacing * CGFloat(columns - 1)) / CGFloat(columns)))
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: spacing), count: columns), spacing: 14) {
                        ForEach(entries) { entry in
                            gridCell(entry, width: cellWidth)
                                .contentShape(Rectangle())
                                .onAppear { prefetch(after: entry) }
                                .onTapGesture { if entry.kind != .other { onOpen(entry) } }
                                .onLongPressGesture(minimumDuration: 0.4) { showOptions(entry) }
                        }
                    }
                    .padding(12)
                }
            }
        } else {
            List(entries) { entry in
                HStack(spacing: 12) {
                    SmbEntryThumbnail(entry: entry, host: host, size: librarySettings.thumbnailSize.rowHeight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).lineLimit(2).foregroundStyle(entry.kind == .other ? .secondary : .primary)
                        if showsParentPath {
                            Text((entry.path as NSString).deletingLastPathComponent)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if !entry.isDirectory {
                            Text(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onAppear { prefetch(after: entry) }
                // Tap = open; press and hold = the options sheet (info, favorite, playlist, copy, check the file...).
                .onTapGesture { if entry.kind != .other { onOpen(entry) } }
                .onLongPressGesture(minimumDuration: 0.4) { showOptions(entry) }
            }
            .listStyle(.plain)
        }
    }

    /// When a cell appears, warm the thumbnails of the next dozen entries (disk → memory), so scrolling on shows
    /// them immediately instead of blank boxes filling in.
    private func prefetch(after entry: SmbEntry) {
        guard let index = entries.firstIndex(of: entry) else { return }
        let upcoming = entries[(index + 1)..<min(entries.count, index + 13)]
            .filter { $0.kind == .video || $0.kind == .image || $0.kind == .audio }
            .map { "smb://\(host)/\($0.path)" }
        guard !upcoming.isEmpty else { return }
        Task(priority: .utility) { await ThumbnailService.shared.warm(Array(upcoming)) }
    }

    private func showOptions(_ entry: SmbEntry) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        optionsEntry = entry
    }

    @ViewBuilder
    private func gridCell(_ entry: SmbEntry, width: CGFloat) -> some View {
        // Every cell is the same 16:9 box so rows line up; folders fill theirs with a big folder symbol.
        let height = width * 9 / 16
        VStack(alignment: .leading, spacing: 5) {
            switch entry.kind {
            case .folder: FolderThumbnailView(size: height, width: width)
            case .video: VideoThumbnailView(source: "smb://\(host)/\(entry.path)", size: height)
            case .image: SmbImageThumbnailView(host: host, path: entry.path, width: width, height: height)
            case .audio: AudioCoverView(source: "smb://\(host)/\(entry.path)", size: height, width: width)
            case .other: SmbEntryThumbnail(entry: entry, host: host, size: height).frame(width: width)
            }
            Text(entry.name).font(.footnote).lineLimit(2).multilineTextAlignment(.leading)
        }
        .frame(width: width, alignment: .leading)
    }


}

/// A picture viewer to present over an SMB folder.
struct ImageViewerTarget: Identifiable {
    let id = UUID()
    let items: [ImageItem]
    let index: Int
}

/// Full-resolution bytes of an SMB picture for the viewer / thumbnails. AMSMB2 first; if that fails (logged, so the
/// real error shows up in the diagnostics log) libVLC renders the picture instead over its own SMB2 module — the
/// route that is known to work against the user's server.
enum SmbImageLoader {
    private static let amsmb2Broken = HostFlags()

    /// `ImageViewerScreen`'s data provider for SMB pictures.
    static func viewerData(_ item: ImageItem) async -> Data? {
        guard let (host, path) = SmbUri.parse(item.source) else { return nil }
        return await data(host: host, path: path, fallbackWidth: 2560)
    }

    static func data(host: String, path: String, fallbackWidth: CGFloat) async -> Data? {
        if !amsmb2Broken.contains(host), let connection = await SmbRegistry.shared.getOrReconnect(host) {
            let result = await withTimeout(seconds: 12) { () -> Data in
                let size = try await connection.fileSize(path: path)
                guard size > 0, size < 80_000_000 else { throw SmbError(message: "kích thước \(size)") }
                return try await connection.readRange(path: path, offset: 0, count: Int(size))
            }
            switch result {
            case .success(let data):
                return data
            case .failure(let error):
                PlaybackDiagnostics.append("image: AMSMB2 read failed for \(path): \(error.localizedDescription) — using VLC")
                amsmb2Broken.insert(host)
            }
        }
        let login = await SmbRegistry.shared.login(for: host)
        guard let cgImage = await ThumbnailService.vlcSnapshot(host: host, path: path, login: login, width: fallbackWidth, position: 0) else {
            PlaybackDiagnostics.append("image: VLC could not render \(path) either")
            return nil
        }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9)
    }

    /// Returns whichever comes first: `body`'s result or a timeout. Deliberately unstructured — AMSMB2 calls do not
    /// observe cancellation, and a task group would wait for the slow call anyway before returning.
    private static func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async -> Result<T, Error> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Error>, Never>) in
            let once = OnceFlag()
            Task {
                let result: Result<T, Error>
                do { result = .success(try await body()) } catch { result = .failure(error) }
                if once.claim() { continuation.resume(returning: result) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() { continuation.resume(returning: .failure(SmbError(message: "quá \(Int(seconds))s không đọc xong"))) }
            }
        }
    }
}

/// True for exactly one caller.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// Thread-safe set of host names.
final class HostFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: Set<String> = []
    func contains(_ host: String) -> Bool { lock.lock(); defer { lock.unlock() }; return hosts.contains(host.lowercased()) }
    func insert(_ host: String) { lock.lock(); hosts.insert(host.lowercased()); lock.unlock() }
}
