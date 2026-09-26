import Foundation
import AVFoundation
import UIKit
import CryptoKit
import MobileVLCKit
import ImageIO

/// Generates and caches thumbnails for videos (a frame a few seconds in, via AVFoundation) and pictures (a downsized
/// copy), for both local files and SMB files (played through the same loopback `SmbHttpProxy` URL used for
/// playback — AVFoundation can read a plain HTTP range-capable URL just like VLCKit can).
actor ThumbnailService {
    static let shared = ThumbnailService()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskDirectory: URL

    /// Application Support/Thumbnails — the app's own storage, not Caches (which iOS empties whenever it likes, so
    /// every folder had to regenerate its thumbnails over SMB). Excluded from iCloud backup: it can be rebuilt.
    static let directory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = support.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    private init() {
        diskDirectory = Self.directory
        // Thumbnails made before this lived in Caches/thumbnails: move them over instead of regenerating.
        let old = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("thumbnails")
        if let files = try? FileManager.default.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.moveItem(at: file, to: Self.directory.appendingPathComponent(file.lastPathComponent))
            }
            try? FileManager.default.removeItem(at: old)
        }
        // Bounded by bytes, not just count: 300 decoded 480px thumbnails alone could take >100MB, on top of libVLC.
        memoryCache.countLimit = 200
        memoryCache.totalCostLimit = 40 * 1024 * 1024
    }

    private func cacheKey(_ source: String) -> String {
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func diskURL(_ key: String) -> URL {
        diskDirectory.appendingPathComponent(key + ".jpg")
    }

    /// Thumbnail for a video at `source` (a local file URL string, or a ready-to-fetch SMB proxy URL). Returns nil if
    /// the frame could not be decoded (unsupported codec, unreachable share, etc).
    func videoThumbnail(source: String, remoteURL: URL?) async -> UIImage? {
        let key = cacheKey(source)
        if let cached = memoryCache.object(forKey: key as NSString) { return cached }
        if let onDisk = loadFromDisk(key) {
            remember(onDisk, key: key)
            return onDisk
        }

        let assetURL: URL?
        if let remoteURL {
            assetURL = remoteURL
        } else {
            assetURL = URL(string: source)
        }
        guard let assetURL else { return nil }

        let asset = AVURLAsset(url: assetURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)

        let time = CMTime(seconds: 3, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        let image = UIImage(cgImage: cgImage)
        remember(image, key: key)
        saveToDisk(image, key: key)
        return image
    }

    /// Already-made thumbnail for `source` (memory or disk), without generating anything — for places that must not
    /// start SMB work, like the file list inside the player while a video is streaming.
    func cachedThumbnail(source: String) -> UIImage? {
        let key = cacheKey(source)
        if let cached = memoryCache.object(forKey: key as NSString) { return cached }
        if let onDisk = loadFromDisk(key) {
            remember(onDisk, key: key)
            return onDisk
        }
        return nil
    }

    /// Thumbnail for an SMB video, taken by libVLC itself (`VLCSnapshotter`) over its own SMB2 module — works
    /// for every format VLC plays (MKV, AVI, HEVC...). One at a time: each is its own SMB session plus a decoder.
    private func makeSmbVideoThumbnail(source: String, host: String, path: String) async -> UIImage? {
        if let cached = cachedThumbnail(source: source) { return cached }
        let key = cacheKey(source)
        let noFrame = diskDirectory.appendingPathComponent(key + ".none")
        // A file libVLC could not take a frame from is not retried on every visit (the log showed the same file
        // re-attempted over and over, each time another SMB session hammering the server).
        if FileManager.default.fileExists(atPath: noFrame.path) { return nil }
        await acquireSmbSlot()
        defer { releaseSmbSlot() }
        if Task.isCancelled { return nil }
        let busy = await Self.videoIsPlaying()
        if busy { return nil }
        if let cached = cachedThumbnail(source: source) { return cached }

        let login = await SmbRegistry.shared.login(for: host)
        var snapshot: CGImage?
        if !SmbRoutePreferences.prefersProxy(source) {
            snapshot = await Self.vlcSnapshot(host: host, path: path, login: login, width: 640, position: 0.1)
        }
        if snapshot == nil, !(await Self.videoIsPlaying()) {
            // libVLC's SMB module gave nothing (or is known not to work for this file): try the AMSMB2 proxy, the
            // way the Android app reads SMB. If that works, playback goes that way too from now on.
            snapshot = await Self.vlcSnapshot(host: host, path: path, login: login, width: 640, position: 0.1, route: .proxy)
            if snapshot != nil {
                SmbRoutePreferences.set(source, proxy: true)
                PlaybackDiagnostics.append("thumb: \(path) works via proxy — remembered for playback")
            }
        }
        guard let cgImage = snapshot else {
            PlaybackDiagnostics.append("thumb: VLC gave no frame for \(path)")
            // Only remember it if nothing else was going on (a video starting mid-way can make it fail too).
            let busyNow = await Self.videoIsPlaying()
            if !busyNow { FileManager.default.createFile(atPath: noFrame.path, contents: nil) }
            return nil
        }
        let image = UIImage(cgImage: cgImage)
        remember(image, key: key)
        saveToDisk(image, key: key)
        return image
    }

    /// Thumbnail for a picture on an SMB share (bytes via `SmbImageLoader`, downsampled without decoding the full
    /// picture).
    private func makeSmbImageThumbnail(source: String, host: String, path: String) async -> UIImage? {
        if let cached = cachedThumbnail(source: source) { return cached }
        await acquireSmbSlot()
        defer { releaseSmbSlot() }
        if Task.isCancelled { return nil }
        if let cached = cachedThumbnail(source: source) { return cached }
        guard let data = await SmbImageLoader.data(host: host, path: path, fallbackWidth: 640) else { return nil }
        return await imageThumbnail(source: source, data: data)
    }

    /// Cover art embedded in a song (ID3/FLAC/MP4 tags...), read by libVLC's own parser — over its SMB2 module for
    /// network files. Songs without a cover get a marker file so they are not parsed again every time.
    private func makeAudioCover(source: String) async -> UIImage? {
        if let cached = cachedThumbnail(source: source) { return cached }
        let key = cacheKey(source)
        let noCover = diskDirectory.appendingPathComponent(key + ".none")
        if FileManager.default.fileExists(atPath: noCover.path) { return nil }

        await acquireSmbSlot()
        defer { releaseSmbSlot() }
        if Task.isCancelled { return nil }
        let busy = await Self.videoIsPlaying()
        if busy { return nil }
        if let cached = cachedThumbnail(source: source) { return cached }

        let media: VLCMedia?
        if let (host, path) = SmbUri.parse(source) {
            let login = await SmbRegistry.shared.login(for: host)
            media = await MainActor.run { SmbPlayback.media(host: host, path: path, route: .direct, login: login) }
        } else {
            media = URL(string: source).map { VLCMedia(url: $0) }
        }
        guard let media, let art = await Self.parseArtwork(media),
              let data = art.jpegData(compressionQuality: 0.9), let cover = Self.downsample(data, maxDimension: 640) else {
            FileManager.default.createFile(atPath: noCover.path, contents: nil)
            return nil
        }
        remember(cover, key: key)
        saveToDisk(cover, key: key)
        return cover
    }

    @MainActor
    private static func parseArtwork(_ media: VLCMedia) async -> UIImage? {
        // parseNetwork | fetchLocal: read the file's own tags even though it is on the network; no online lookups.
        let options = VLCMediaParsingOptions(rawValue: 0x01 | 0x02)
        _ = media.parse(options: options, timeout: 15_000)
        let deadline = Date().addingTimeInterval(17)
        while media.parsedStatus.rawValue == 0, Date() < deadline { // 0 = still parsing ("init")
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return media.metaData.artwork
    }

    /// A thumbnail job that was waiting for its turn must not start once a video is open: it would be another SMB
    /// session + decoder competing with playback.
    @MainActor
    private static func videoIsPlaying() -> Bool {
        PlaybackActivity.shared.isBusy
    }

    // MARK: - Public entry points (de-duplicated: a thumbnail asked for by a visible cell and by the folder prefill at
    // the same time is made once).

    func smbVideoThumbnail(source: String, host: String, path: String) async -> UIImage? {
        await once(source) { await self.makeSmbVideoThumbnail(source: source, host: host, path: path) }
    }

    func smbImageThumbnail(source: String, host: String, path: String) async -> UIImage? {
        await once(source) { await self.makeSmbImageThumbnail(source: source, host: host, path: path) }
    }

    func audioCover(source: String) async -> UIImage? {
        await once(source) { await self.makeAudioCover(source: source) }
    }

    func folderThumbnail(host: String, path: String) async -> UIImage? {
        await once("smbfolder://\(host)/\(path)") { await self.makeFolderThumbnail(host: host, path: path) }
    }

    private var inflight: [String: Task<UIImage?, Never>] = [:]

    private func once(_ key: String, _ make: @escaping () async -> UIImage?) async -> UIImage? {
        if let running = inflight[key] { return await running.value }
        let task = Task { await make() }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        return result
    }

    /// Fast mode: make every thumbnail of a folder ahead of the scroll, `jobLimit` at a time, top to bottom. Stops
    /// when the folder view goes away (task cancelled) or a video opens.
    func prefill(host: String, entries: [SmbEntry]) async {
        let queue = PrefillQueue(entries.filter { $0.kind != .other })
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    while !Task.isCancelled, ThumbnailPolicy.shared.isFast, let entry = await queue.next() {
                        let source = "smb://\(host)/\(entry.path)"
                        switch entry.kind {
                        case .video: _ = await self.smbVideoThumbnail(source: source, host: host, path: entry.path)
                        case .image: _ = await self.smbImageThumbnail(source: source, host: host, path: entry.path)
                        case .audio: _ = await self.audioCover(source: source)
                        case .folder: _ = await self.folderThumbnail(host: host, path: entry.path)
                        case .other: break
                        }
                    }
                }
            }
        }
        ThumbnailEvents.shared.changedSoon()
    }


    // MARK: - SMB job slots (limit follows ThumbnailPolicy: 3 in fast mode, 1 otherwise)

    private var smbActive = 0
    private var smbWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireSmbSlot() async {
        if smbActive < ThumbnailPolicy.shared.jobLimit { smbActive += 1; return }
        await withCheckedContinuation { smbWaiters.append($0) } // a releasing caller hands its slot over
    }

    private func releaseSmbSlot() {
        // Hand the slot over only while under the current limit (it drops to 1 when a video opens).
        if !smbWaiters.isEmpty, smbActive <= ThumbnailPolicy.shared.jobLimit {
            smbWaiters.removeFirst().resume()
        } else {
            smbActive -= 1
        }
    }

    /// The limit went up (video closed / fast mode switched on): start waiting jobs into the new free slots.
    func policyChanged() {
        while !smbWaiters.isEmpty, smbActive < ThumbnailPolicy.shared.jobLimit {
            smbActive += 1
            smbWaiters.removeFirst().resume()
        }
    }

    /// One frame of an SMB file rendered by libVLC (off the main thread, cancellable — see VLCSnapshotter),
    /// at most `width` px wide, at `position` (0...1) of its duration.
    static func vlcSnapshot(host: String, path: String, login: SmbPlayback.Login?, width: CGFloat, position: Float,
                            route: SmbPlaybackRoute = .direct) async -> CGImage? {
        guard let target = SmbPlayback.location(host: host, path: path, route: route, login: login) else { return nil }
        return await VLCSnapshotter.snapshot(location: target.url, options: target.options,
                                             maxWidth: Int(width), position: position)
    }

    /// Downsized thumbnail for a picture at `source`; `data` is provided directly for SMB images (fetched by the
    /// caller through `SmbConnection.readRange`), or left nil to read a local file URL directly.
    func imageThumbnail(source: String, data: Data?) async -> UIImage? {
        let key = cacheKey(source)
        if let cached = memoryCache.object(forKey: key as NSString) { return cached }
        if let onDisk = loadFromDisk(key) {
            remember(onDisk, key: key)
            return onDisk
        }

        let sourceData: Data?
        if let data {
            sourceData = data
        } else if let url = URL(string: source) {
            sourceData = try? Data(contentsOf: url)
        } else {
            sourceData = nil
        }
        guard let sourceData, let thumbnail = Self.downsample(sourceData, maxDimension: 640) else { return nil }
        remember(thumbnail, key: key)
        saveToDisk(thumbnail, key: key)
        return thumbnail
    }

    /// ImageIO thumbnail straight from the encoded bytes — never materializes the full-size bitmap (a 48MP photo is
    /// ~190MB decoded; a few at once got the app killed by iOS).
    static func downsample(_ data: Data, maxDimension: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func remember(_ image: UIImage, key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)
    }

    private func loadFromDisk(_ key: String) -> UIImage? {
        guard let data = try? Data(contentsOf: diskURL(key)) else { return nil }
        // `UIImage(data:)` would defer decoding to the first draw — on the main thread, mid-scroll. ImageIO with
        // ShouldCacheImmediately decodes here, off the main thread.
        return Self.downsample(data, maxDimension: 800)
    }

    private func saveToDisk(_ image: UIImage, key: String) {
        guard let data = image.jpegData(compressionQuality: 0.75) else { return }
        try? data.write(to: diskURL(key))
    }

    /// A folder's picture made from what is inside it: up to four of its pictures/videos in a 2×2 mosaic (one fills
    /// the whole tile). Uses thumbnails that already exist first and makes at most two new ones, so a folder view
    /// does not turn into dozens of SMB sessions. Folders with nothing to show get a marker and keep the plain icon.
    private func makeFolderThumbnail(host: String, path: String) async -> UIImage? {
        let source = "smbfolder://\(host)/\(path)"
        if let cached = cachedThumbnail(source: source) { return cached }
        let key = cacheKey(source)
        let empty = diskDirectory.appendingPathComponent(key + ".none")
        if let date = (try? FileManager.default.attributesOfItem(atPath: empty.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(date) < 24 * 3600 { return nil } // re-check empty folders once a day
        if await Self.videoIsPlaying() { return nil }
        guard let connection = await SmbRegistry.shared.getOrReconnect(host),
              let items = try? await connection.list(path: path) else { return nil }
        let media = items.filter { $0.isImage || $0.isVideo }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .prefix(16)

        var tiles: [UIImage] = []
        var missing: [SmbEntry] = []
        for entry in media where tiles.count < 4 {
            if let existing = cachedThumbnail(source: "smb://\(host)/\(entry.path)") { tiles.append(existing) }
            else { missing.append(entry) }
        }
        var made = 0
        for entry in missing where tiles.count < 4 && made < 2 {
            if Task.isCancelled { return nil }
            let entrySource = "smb://\(host)/\(entry.path)"
            let image = entry.isImage
                ? await smbImageThumbnail(source: entrySource, host: host, path: entry.path)
                : await smbVideoThumbnail(source: entrySource, host: host, path: entry.path)
            made += 1
            if let image { tiles.append(image) }
        }
        guard !tiles.isEmpty else {
            if !media.isEmpty && made < missing.count { return nil } // not finished — try again next time
            FileManager.default.createFile(atPath: empty.path, contents: nil)
            return nil
        }
        let mosaic = Self.mosaic(tiles, size: CGSize(width: 640, height: 360))
        remember(mosaic, key: key)
        saveToDisk(mosaic, key: key)
        return mosaic
    }

    private static func mosaic(_ tiles: [UIImage], size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let gap: CGFloat = 4
            let rects: [CGRect]
            switch tiles.count {
            case 1:
                rects = [CGRect(origin: .zero, size: size)]
            case 2:
                let w = (size.width - gap) / 2
                rects = [CGRect(x: 0, y: 0, width: w, height: size.height),
                         CGRect(x: w + gap, y: 0, width: w, height: size.height)]
            case 3:
                let w = (size.width - gap) / 2, h = (size.height - gap) / 2
                rects = [CGRect(x: 0, y: 0, width: w, height: size.height),
                         CGRect(x: w + gap, y: 0, width: w, height: h),
                         CGRect(x: w + gap, y: h + gap, width: w, height: h)]
            default:
                let w = (size.width - gap) / 2, h = (size.height - gap) / 2
                rects = [CGRect(x: 0, y: 0, width: w, height: h), CGRect(x: w + gap, y: 0, width: w, height: h),
                         CGRect(x: 0, y: h + gap, width: w, height: h), CGRect(x: w + gap, y: h + gap, width: w, height: h)]
            }
            for (tile, rect) in zip(tiles, rects) {
                // Aspect-fill into the cell.
                let scale = max(rect.width / tile.size.width, rect.height / tile.size.height)
                let drawn = CGSize(width: tile.size.width * scale, height: tile.size.height * scale)
                context.cgContext.saveGState()
                context.cgContext.clip(to: rect)
                tile.draw(in: CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                                     width: drawn.width, height: drawn.height))
                context.cgContext.restoreGState()
            }
        }
    }

    /// Loads already-made thumbnails for `sources` from disk into memory (decoded), so rows about to scroll into
    /// view show theirs at once. Disk only — never starts SMB work.
    func warm(_ sources: [String]) {
        for source in sources {
            let key = cacheKey(source)
            guard memoryCache.object(forKey: key as NSString) == nil, let image = loadFromDisk(key) else { continue }
            remember(image, key: key)
        }
    }

    /// Memory only (the disk copies stay): used when the app goes to the background.
    func clearMemory() {
        memoryCache.removeAllObjects()
    }

    /// Drops one entry's thumbnail (and its "no frame / no cover" marker) so it is made again.
    func forget(source: String) {
        let key = cacheKey(source)
        memoryCache.removeObject(forKey: key as NSString)
        try? FileManager.default.removeItem(at: diskURL(key))
        try? FileManager.default.removeItem(at: diskDirectory.appendingPathComponent(key + ".none"))
    }

    /// Size of the thumbnail folder, and wiping it (Cài đặt).
    nonisolated static func diskUsage() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clearAll() {
        memoryCache.removeAllObjects()
        let files = (try? FileManager.default.contentsOfDirectory(at: diskDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}

private extension UIImage {
    func resized(maxDimension: CGFloat) -> UIImage {
        let scale = min(1, maxDimension / max(size.width, size.height))
        guard scale < 1 else { return self }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

/// Hands a folder's entries out one at a time to the prefill workers.
private actor PrefillQueue {
    private var entries: [SmbEntry]
    private var index = 0
    init(_ entries: [SmbEntry]) { self.entries = entries }
    func next() -> SmbEntry? {
        guard index < entries.count else { return nil }
        defer { index += 1 }
        return entries[index]
    }
}
