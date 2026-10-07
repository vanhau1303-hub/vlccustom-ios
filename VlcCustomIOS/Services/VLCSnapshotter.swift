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
    /// `position` (0…1) of the duration — or the first frame for short/unseekable files and still pictures (0).
    /// A black / blank frame (fade, scene change, intro card) is not kept: other spots are tried in the same session
    /// and the first one with a real picture wins (the brightest one if every spot is dark).
    static func snapshot(location: String, options: [String], maxWidth: Int = 640, position: Float = 0.25,
                         timeout: TimeInterval = 20, spotTimeout: TimeInterval = 12) async -> CGImage? {
        var positions: [Float] = []
        if position > 0 {
            for p in [position] + spots where !positions.contains(p) { positions.append(p) }
        }
        return await run { grab(location: location, options: options, maxWidth: maxWidth, positions: positions,
                                firstUsable: true, timeout: timeout, spotTimeout: spotTimeout) }.first
    }

    /// The agreed spots for a normal thumbnail, in order: 25%, then 40%, 60%, 15%, 75% when the frame is black.
    static let spots: [Float] = [0.25, 0.4, 0.6, 0.15, 0.75]

    /// Several frames of one video (thumbnail động): one libVLC session seeking from spot to spot. Spots that give no
    /// frame are skipped.
    static func frames(location: String, options: [String], maxWidth: Int, positions: [Float],
                       timeout: TimeInterval = 45) async -> [CGImage] {
        await run { grab(location: location, options: options, maxWidth: maxWidth, positions: positions,
                         firstUsable: false, timeout: timeout) }
    }

    /// At most two libVLC grab players at once in the whole app (folder prefill, cells on screen and the background
    /// pass all ask at the same time): each is a decoder plus an SMB stream, and too many together got the app
    /// killed for memory when opening big folders.
    private static let slots = DispatchSemaphore(value: 2)

    private static func run(_ work: @escaping @Sendable () -> [CGImage]) async -> [CGImage] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let startGeneration = generation
                while slots.wait(timeout: .now() + 0.25) == .timedOut {
                    if generation != startGeneration { continuation.resume(returning: []); return }
                }
                defer { slots.signal() }
                continuation.resume(returning: work())
            }
        }
    }

    /// Mean brightness and spread (0…1) of a frame, from a 32×18 grey copy.
    static func brightness(_ image: CGImage) -> (mean: Double, spread: Double) {
        let w = 32, h = 18
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return (1, 1) }
        let values = pixels.map { Double($0) / 255 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return (mean, variance.squareRoot())
    }

    /// Not black, and not one flat colour (blank / half-decoded frame).
    static func isUsable(_ image: CGImage) -> Bool {
        let b = brightness(image)
        return b.mean > 0.08 && b.spread > 0.035
    }

    // MARK: - Blocking implementation (background thread only)

    /// One libVLC player rendering into a `FrameSink`.
    private final class Session {
        let player: OpaquePointer
        let sink: FrameSink
        private let opaque: UnsafeMutableRawPointer

        init?(location: String, options: [String], maxWidth: Int, minFrames: Int) {
            let instance = VLCLibrary.shared().instance
            guard let media = libvlc_media_new_location(OpaquePointer(instance), location) else { return nil }
            // No ":avcodec-skip-idct": skipping the IDCT on every frame gave software-decoded videos grey frames.
            for option in options + [":no-audio", ":no-spu", ":avcodec-threads=2", ":avcodec-skiploopfilter=4",
                                     ":deinterlace=0"] {
                libvlc_media_add_option(media, option)
            }
            guard let player = libvlc_media_player_new_from_media(media) else {
                libvlc_media_release(media)
                return nil
            }
            libvlc_media_release(media)
            self.player = player
            sink = FrameSink(maxWidth: maxWidth, minFrames: minFrames)
            opaque = Unmanaged.passRetained(sink).toOpaque()
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
        }

        /// The next frame, cut to the picture's visible size: libVLC hands over the coded size (e.g. 1920×1058 for a
        /// 1918×1038 film), and the extra rows were the black band under some thumbnails.
        func frame(until deadline: Date, cancelled: () -> Bool) -> CGImage? {
            guard let image = sink.wait(until: deadline, cancelled: cancelled) else { return nil }
            var w: UInt32 = 0, h: UInt32 = 0
            guard libvlc_video_get_size(player, 0, &w, &h) == 0 else { return image }
            return sink.crop(image, visibleWidth: Int(w), visibleHeight: Int(h))
        }

        func close() {
            libvlc_media_player_stop(player)
            libvlc_media_player_release(player)
            Unmanaged<FrameSink>.fromOpaque(opaque).release()
        }
    }

    /// Spots in a video are taken by opening the file again at each one (`:start-time`) rather than seeking a
    /// playing player: after a seek libVLC kept handing over frames from before it (the film's black opening for
    /// most Blu-ray rips), so whole folders got black thumbnails. Opening at the spot, the first frames shown are
    /// from there. Checked on the user's files with libVLC 3.0.23 (Cast Away, Forrest Gump, The Green Mile...).
    private static func grab(location: String, options: [String], maxWidth: Int, positions: [Float],
                             firstUsable: Bool, timeout: TimeInterval, spotTimeout: TimeInterval = 12) -> [CGImage] {
        let startGeneration = generation
        let cancelled = { generation != startGeneration }
        let deadline = Date().addingTimeInterval(timeout)
        var results: [CGImage] = []
        var best: (image: CGImage, score: Double)?
        /// Keeps the best frame seen; true once one is good enough to stop looking.
        func consider(_ image: CGImage) -> Bool {
            let b = brightness(image)
            let score = b.mean + b.spread
            if best == nil || score > best!.score { best = (image, score) }
            return b.mean > 0.08 && b.spread > 0.035
        }

        // 1) Open once to learn the length (and to take the picture itself for stills / short clips).
        guard let probe = Session(location: location, options: options, maxWidth: maxWidth,
                                  minFrames: positions.isEmpty ? 1 : 3) else { return [] }
        var length: Int64 = 0
        var first: CGImage?
        while Date() < deadline, !cancelled() {
            length = libvlc_media_player_get_length(probe.player)
            if length > 0 && !positions.isEmpty && length > 20_000 { break }
            if let image = probe.frame(until: min(deadline, Date().addingTimeInterval(0.2)), cancelled: cancelled) {
                first = image
                length = libvlc_media_player_get_length(probe.player)
                break
            }
        }
        if positions.isEmpty || length <= 20_000 {
            // Still picture, short clip or unknown length: what this player shows. For a clip, watch a little longer
            // for a frame that is not black.
            if let image = first {
                if firstUsable {
                    var current = image
                    var tries = 0
                    while !consider(current), !positions.isEmpty, length > 0, tries < 6, !cancelled(), Date() < deadline {
                        probe.sink.reset()
                        guard let next = probe.frame(until: min(deadline, Date().addingTimeInterval(1.5)), cancelled: cancelled)
                        else { break }
                        current = next
                        tries += 1
                    }
                } else {
                    results.append(image)
                }
            }
            probe.close()
            if cancelled() { return [] }
            return firstUsable ? (best.map { [$0.image] } ?? []) : results
        }
        // Closed before the spots: only one player per grab at a time (memory).
        probe.close()

        // 2) One fresh player per spot, opened right there.
        let reserve: TimeInterval = 6
        for position in positions {
            let spotDeadline = min(deadline.addingTimeInterval(-reserve), Date().addingTimeInterval(spotTimeout))
            if cancelled() || Date() >= spotDeadline { break }
            let start = Double(length) * Double(position) / 1000
            guard let session = Session(location: location, options: options + [":start-time=\(start)"],
                                        maxWidth: maxWidth, minFrames: 2) else { continue }
            let image = session.frame(until: spotDeadline, cancelled: cancelled)
            session.close()
            guard let image else { continue }
            if firstUsable {
                if consider(image) { break }
            } else {
                results.append(image)
            }
        }
        if cancelled() { return [] }

        // 3) Nothing from any spot (fragmented MP4 without an index can take longer to open at a spot than the
        // whole budget): a frame from the start beats no thumbnail.
        if firstUsable ? best == nil : results.isEmpty,
           let probe = Session(location: location, options: options, maxWidth: maxWidth, minFrames: 3) {
            defer { probe.close() }
            let fallbackDeadline = max(deadline, Date().addingTimeInterval(reserve))
            if let image = probe.frame(until: fallbackDeadline, cancelled: cancelled) {
                if firstUsable {
                    // The opening is often black: give it a few more frames to show something.
                    var current = image
                    while !consider(current), !cancelled(), Date() < fallbackDeadline {
                        probe.sink.reset()
                        guard let next = probe.frame(until: min(fallbackDeadline, Date().addingTimeInterval(1.5)),
                                                     cancelled: cancelled) else { break }
                        current = next
                    }
                } else {
                    results.append(image)
                }
            }
        }
        if cancelled() { return [] }
        return firstUsable ? (best.map { [$0.image] } ?? []) : results
    }
}

/// libVLC renders into `buffer`; after a few frames (the very first ones are often black / half-decoded) the latest
/// one is copied out as a CGImage.
private final class FrameSink: @unchecked Sendable {
    let maxWidth: Int
    let minFrames: Int
    private(set) var buffer: UnsafeMutableRawPointer?
    private var width = 0, height = 0
    /// The size libVLC decodes at (coded size, may include padding rows/columns).
    private var sourceWidth = 0, sourceHeight = 0
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
        sourceWidth = Int(w.pointee); sourceHeight = Int(h.pointee)
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

    /// `image` without the padding outside the picture's visible `visibleWidth`×`visibleHeight` (in source pixels).
    func crop(_ image: CGImage, visibleWidth: Int, visibleHeight: Int) -> CGImage {
        condition.lock()
        let sw = sourceWidth, sh = sourceHeight
        condition.unlock()
        guard sw > 0, sh > 0, visibleWidth > 0, visibleHeight > 0,
              visibleWidth <= sw, visibleHeight <= sh, visibleWidth < sw || visibleHeight < sh else { return image }
        let w = Int((Double(image.width) * Double(visibleWidth) / Double(sw)).rounded())
        let h = Int((Double(image.height) * Double(visibleHeight) / Double(sh)).rounded())
        guard w > 1, h > 1 else { return image }
        return image.cropping(to: CGRect(x: 0, y: 0, width: w, height: h)) ?? image
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
