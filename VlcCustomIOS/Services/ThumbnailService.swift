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

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDirectory = caches.appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
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

    /// Thumbnail for an SMB video, taken by libVLC itself (`VLCMediaThumbnailer`) over its own SMB2 module — works
    /// for every format VLC plays (MKV, AVI, HEVC...). One at a time: each is its own SMB session plus a decoder.
    func smbVideoThumbnail(source: String, host: String, path: String) async -> UIImage? {
        if let cached = cachedThumbnail(source: source) { return cached }
        await acquireSmbSlot()
        defer { releaseSmbSlot() }
        if Task.isCancelled { return nil }
        if let cached = cachedThumbnail(source: source) { return cached }

        let login = await SmbRegistry.shared.login(for: host)
        guard let cgImage = await Self.vlcSnapshot(host: host, path: path, login: login, width: 480, position: 0.1) else {
            PlaybackDiagnostics.append("thumb: VLC gave no frame for \(path)")
            return nil
        }
        let image = UIImage(cgImage: cgImage)
        let key = cacheKey(source)
        remember(image, key: key)
        saveToDisk(image, key: key)
        return image
    }

    /// Thumbnail for a picture on an SMB share (bytes via `SmbImageLoader`, downsampled without decoding the full
    /// picture).
    func smbImageThumbnail(source: String, host: String, path: String) async -> UIImage? {
        if let cached = cachedThumbnail(source: source) { return cached }
        await acquireSmbSlot()
        defer { releaseSmbSlot() }
        if Task.isCancelled { return nil }
        if let cached = cachedThumbnail(source: source) { return cached }
        guard let data = await SmbImageLoader.data(host: host, path: path, fallbackWidth: 480) else { return nil }
        return await imageThumbnail(source: source, data: data)
    }

    private var smbActive = 0
    private var smbWaiters: [CheckedContinuation<Void, Never>] = []
    private static let maxSmbJobs = 1

    private func acquireSmbSlot() async {
        if smbActive < Self.maxSmbJobs { smbActive += 1; return }
        await withCheckedContinuation { smbWaiters.append($0) } // the releasing caller hands its slot over
    }

    private func releaseSmbSlot() {
        if smbWaiters.isEmpty { smbActive -= 1 } else { smbWaiters.removeFirst().resume() }
    }

    /// One frame of an SMB file rendered by libVLC, `width` px wide, at `position` (0...1) of its duration.
    @MainActor
    static func vlcSnapshot(host: String, path: String, login: SmbPlayback.Login?, width: CGFloat, position: Float) async -> CGImage? {
        guard let media = SmbPlayback.media(host: host, path: path, route: .direct, login: login) else { return nil }
        return await withCheckedContinuation { continuation in
            let job = ThumbnailJob(continuation: continuation)
            let thumbnailer = VLCMediaThumbnailer(media: media, andDelegate: job)
            thumbnailer.thumbnailWidth = width
            thumbnailer.snapshotPosition = position
            job.start(thumbnailer)
        }
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
        guard let sourceData, let thumbnail = Self.downsample(sourceData, maxDimension: 480) else { return nil }
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
        return UIImage(data: data)
    }

    private func saveToDisk(_ image: UIImage, key: String) {
        guard let data = image.jpegData(compressionQuality: 0.7) else { return }
        try? data.write(to: diskURL(key))
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

/// One `VLCMediaThumbnailer` run. Keeps itself (and the thumbnailer) alive in `inFlight` until libVLC calls back —
/// releasing a thumbnailer while libVLC is still working on it crashes — while the waiting caller is released after
/// at most 20s regardless.
private final class ThumbnailJob: NSObject, VLCMediaThumbnailerDelegate {
    private static var inFlight = Set<ThumbnailJob>()

    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var thumbnailer: VLCMediaThumbnailer?

    init(continuation: CheckedContinuation<CGImage?, Never>) {
        self.continuation = continuation
    }

    func start(_ thumbnailer: VLCMediaThumbnailer) {
        self.thumbnailer = thumbnailer
        Self.inFlight.insert(self)
        thumbnailer.fetchThumbnail()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.resume(nil) }
        // Hard cleanup if libVLC never calls back at all.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in self?.done() }
    }

    func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
        DispatchQueue.main.async { self.resume(nil); self.done() }
    }

    func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer, didFinishThumbnail thumbnail: CGImage) {
        DispatchQueue.main.async { self.resume(thumbnail); self.done() }
    }

    private func resume(_ image: CGImage?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: image)
    }

    private func done() {
        // Let go on the next turn, not from inside libVLC's own callback.
        DispatchQueue.main.async {
            self.thumbnailer = nil
            Self.inFlight.remove(self)
        }
    }
}
