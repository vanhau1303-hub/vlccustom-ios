import Foundation
import AVFoundation
import UIKit
import CryptoKit
import MobileVLCKit

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
        memoryCache.countLimit = 300
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
            memoryCache.setObject(onDisk, forKey: key as NSString)
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
        memoryCache.setObject(image, forKey: key as NSString)
        saveToDisk(image, key: key)
        return image
    }

    /// Thumbnail for an SMB video, taken by libVLC itself (`VLCMediaThumbnailer`) over its own SMB2 module — works
    /// for every format VLC plays (MKV, AVI, HEVC...), unlike AVFoundation. Falls back to AVFoundation through the
    /// proxy (MP4/MOV only) if VLC could not produce a frame. At most two run at once: each one is its own SMB
    /// session to the server, and a folder full of rows would otherwise open dozens together.
    func smbVideoThumbnail(source: String, host: String, path: String) async -> UIImage? {
        let key = cacheKey(source)
        if let cached = memoryCache.object(forKey: key as NSString) { return cached }
        if let onDisk = loadFromDisk(key) {
            memoryCache.setObject(onDisk, forKey: key as NSString)
            return onDisk
        }

        await acquireSmbSlot()
        defer { releaseSmbSlot() }
        if Task.isCancelled { return nil }

        let login = await SmbRegistry.shared.login(for: host)
        if let cgImage = await Self.vlcThumbnail(host: host, path: path, login: login) {
            let image = UIImage(cgImage: cgImage)
            memoryCache.setObject(image, forKey: key as NSString)
            saveToDisk(image, key: key)
            return image
        }
        PlaybackDiagnostics.append("thumb: VLC gave no frame for \(path), trying AVFoundation via proxy")
        let remote = try? SmbHttpProxy.shared.url(host: host, path: path)
        return await videoThumbnail(source: source, remoteURL: remote)
    }

    private var smbActive = 0
    private var smbWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireSmbSlot() async {
        if smbActive < 2 { smbActive += 1; return }
        await withCheckedContinuation { smbWaiters.append($0) } // the releasing caller hands its slot over
    }

    private func releaseSmbSlot() {
        if smbWaiters.isEmpty { smbActive -= 1 } else { smbWaiters.removeFirst().resume() }
    }

    @MainActor
    private static func vlcThumbnail(host: String, path: String, login: SmbPlayback.Login?) async -> CGImage? {
        guard let media = SmbPlayback.media(host: host, path: path, route: .direct, login: login) else { return nil }
        let delegate = ThumbnailerDelegate()
        let image: CGImage? = await withCheckedContinuation { continuation in
            delegate.continuation = continuation
            let thumbnailer = VLCMediaThumbnailer(media: media, andDelegate: delegate)
            thumbnailer.thumbnailWidth = 480
            thumbnailer.snapshotPosition = 0.1
            delegate.thumbnailer = thumbnailer
            thumbnailer.fetchThumbnail()
            // Belt and braces on top of VLCKit's own timeout: never leave a row waiting forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { delegate.finish(nil) }
        }
        return withExtendedLifetime(delegate) { image }
    }

    /// Downsized thumbnail for a picture at `source`; `data` is provided directly for SMB images (fetched by the
    /// caller through `SmbConnection.readRange`), or left nil to read a local file URL directly.
    func imageThumbnail(source: String, data: Data?) async -> UIImage? {
        let key = cacheKey(source)
        if let cached = memoryCache.object(forKey: key as NSString) { return cached }
        if let onDisk = loadFromDisk(key) {
            memoryCache.setObject(onDisk, forKey: key as NSString)
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
        guard let sourceData, let original = UIImage(data: sourceData) else { return nil }
        let thumbnail = original.resized(maxDimension: 480)
        memoryCache.setObject(thumbnail, forKey: key as NSString)
        saveToDisk(thumbnail, key: key)
        return thumbnail
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

/// Bridges `VLCMediaThumbnailer`'s delegate callbacks to a continuation (resumed exactly once).
private final class ThumbnailerDelegate: NSObject, VLCMediaThumbnailerDelegate {
    var continuation: CheckedContinuation<CGImage?, Never>?
    var thumbnailer: VLCMediaThumbnailer?

    func mediaThumbnailerDidTimeOut(_ mediaThumbnailer: VLCMediaThumbnailer) {
        finish(nil)
    }

    func mediaThumbnailer(_ mediaThumbnailer: VLCMediaThumbnailer, didFinishThumbnail thumbnail: CGImage) {
        finish(thumbnail)
    }

    func finish(_ image: CGImage?) {
        DispatchQueue.main.async {
            guard let continuation = self.continuation else { return }
            self.continuation = nil
            self.thumbnailer = nil
            continuation.resume(returning: image)
        }
    }
}
