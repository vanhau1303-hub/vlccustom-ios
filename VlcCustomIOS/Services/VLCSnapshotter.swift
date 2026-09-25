import Foundation
import CoreGraphics
import MobileVLCKit

/// Grabs one frame of a video with libVLC — entirely off the main thread, and cancellable.
///
/// Replaces VLCKit's `VLCMediaThumbnailer`, which deadlocked the app (real crash report: watchdog 0x8BADF00D, main
/// thread stuck): its video thread waits on the main thread for every frame (`performSelectorOnMainThread …
/// waitUntilDone:YES`), the main thread then takes the player lock (`libvlc_media_player_get_position`), and a
/// timed-out stop on another thread holds that lock while waiting for the video thread. Over slow SMB, with several
/// thumbnails at once, that cycle closed. It also forced software decoding and kept going for 45 s on network files.
///
/// Here libVLC renders into our own buffer (video callbacks), frames are copied on libVLC's video thread, and
/// everything else — play, seek, stop, release — runs on a background thread. `cancelAll()` (a video was opened)
/// stops every grab in progress right away.
final class VLCSnapshotter: @unchecked Sendable {
    private static let lock = NSLock()
    private static var cancelGeneration = 0

    /// Abandon every grab in progress (they stop their libVLC player and return nil).
    static func cancelAll() {
        lock.lock(); cancelGeneration += 1; lock.unlock()
    }

    private static var generation: Int {
        lock.lock(); defer { lock.unlock() }; return cancelGeneration
    }

    /// One frame of `location` (with libVLC `options`, e.g. SMB login), at most `maxWidth` px wide, taken at
    /// `position` (0…1) of the duration — or the first frame for short/unseekable files and still pictures.
    static func snapshot(location: String, options: [String], maxWidth: Int = 640, position: Float = 0.1,
                         timeout: TimeInterval = 18) async -> CGImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: grab(location: location, options: options, maxWidth: maxWidth,
                                                    position: position, timeout: timeout))
            }
        }
    }

    // MARK: - Blocking implementation (background thread only)

    private static func grab(location: String, options: [String], maxWidth: Int, position: Float, timeout: TimeInterval) -> CGImage? {
        let instance = VLCLibrary.shared().instance
        let startGeneration = generation
        let cancelled = { generation != startGeneration }

        guard let media = libvlc_media_new_location(OpaquePointer(instance), location) else { return nil }
        for option in options + [":no-audio", ":no-spu", ":avcodec-threads=2", ":avcodec-skiploopfilter=4",
                                 ":avcodec-skip-idct=4", ":deinterlace=0"] {
            libvlc_media_add_option(media, option)
        }
        guard let player = libvlc_media_player_new_from_media(media) else {
            libvlc_media_release(media)
            return nil
        }
        libvlc_media_release(media)

        // A still picture is displayed once; for video the first frames are skipped (often black/half-decoded).
        let frame = FrameSink(maxWidth: maxWidth, minFrames: position > 0 ? 3 : 1)
        let opaque = Unmanaged.passRetained(frame).toOpaque()
        libvlc_video_set_callbacks(player, { opaque, planes in
            let sink = Unmanaged<FrameSink>.fromOpaque(opaque!).takeUnretainedValue()
            planes?.pointee = sink.buffer
            return nil
        }, nil, { opaque, _ in
            Unmanaged<FrameSink>.fromOpaque(opaque!).takeUnretainedValue().frameShown()
        }, opaque)
        libvlc_video_set_format_callbacks(player, { opaque, chroma, width, height, pitches, lines in
            let sink = Unmanaged<FrameSink>.fromOpaque(opaque!.pointee!).takeUnretainedValue()
            return sink.setup(chroma: chroma, width: width, height: height, pitches: pitches, lines: lines)
        }, nil)

        libvlc_media_player_play(player)
        let deadline = Date().addingTimeInterval(timeout)

        // 1) first frames arrive
        var image = frame.wait(until: deadline, cancelled: cancelled)
        // 2) jump to the requested spot for a representative frame (skipped for short files / pictures)
        let length = libvlc_media_player_get_length(player)
        if image != nil, !cancelled(), position > 0, length > 20_000 {
            frame.reset()
            libvlc_media_player_set_position(player, position)
            if let later = frame.wait(until: min(deadline, Date().addingTimeInterval(8)), cancelled: cancelled) {
                image = later
            }
        }

        libvlc_media_player_stop(player)
        libvlc_media_player_release(player)
        Unmanaged<FrameSink>.fromOpaque(opaque).release()
        return cancelled() ? nil : image
    }
}

/// libVLC renders into `buffer`; after a few frames (the very first ones are often black / half-decoded) the latest
/// one is copied out as a CGImage.
private final class FrameSink: @unchecked Sendable {
    let maxWidth: Int
    let minFrames: Int
    private(set) var buffer: UnsafeMutableRawPointer?
    private var width = 0, height = 0
    private var frames = 0
    private var image: CGImage?
    private let condition = NSCondition()

    init(maxWidth: Int, minFrames: Int) {
        self.maxWidth = maxWidth
        self.minFrames = minFrames
    }

    deinit { buffer?.deallocate() }

    /// libVLC tells us the source size; we pick the output size (aspect kept) and chroma.
    func setup(chroma: UnsafeMutablePointer<CChar>?, width w: UnsafeMutablePointer<UInt32>?, height h: UnsafeMutablePointer<UInt32>?,
               pitches: UnsafeMutablePointer<UInt32>?, lines: UnsafeMutablePointer<UInt32>?) -> UInt32 {
        guard let chroma, let w, let h, let pitches, let lines, w.pointee > 0, h.pointee > 0 else { return 0 }
        let scale = min(1, Double(maxWidth) / Double(w.pointee))
        width = max(2, Int(Double(w.pointee) * scale) & ~1)
        height = max(2, Int(Double(h.pointee) * scale) & ~1)
        // "RGBA", like VLCKit's own thumbnailer.
        chroma[0] = CChar(UInt8(ascii: "R")); chroma[1] = CChar(UInt8(ascii: "G"))
        chroma[2] = CChar(UInt8(ascii: "B")); chroma[3] = CChar(UInt8(ascii: "A"))
        w.pointee = UInt32(width); h.pointee = UInt32(height)
        pitches[0] = UInt32(width * 4); lines[0] = UInt32(height)
        buffer?.deallocate()
        buffer = UnsafeMutableRawPointer.allocate(byteCount: width * height * 4, alignment: 64)
        return 1
    }

    /// On libVLC's video thread, once per displayed frame.
    func frameShown() {
        guard let buffer else { return }
        condition.lock()
        frames += 1
        if frames >= minFrames {
            let data = Data(bytes: buffer, count: width * height * 4)
            if let provider = CGDataProvider(data: data as CFData) {
                image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            }
            condition.signal()
        }
        condition.unlock()
    }

    func reset() {
        condition.lock(); frames = 0; image = nil; condition.unlock()
    }

    /// Waits (background thread) for a usable frame, until `deadline` or cancellation.
    func wait(until deadline: Date, cancelled: () -> Bool) -> CGImage? {
        condition.lock()
        defer { condition.unlock() }
        while image == nil, Date() < deadline, !cancelled() {
            _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.25)))
        }
        return image
    }
}
