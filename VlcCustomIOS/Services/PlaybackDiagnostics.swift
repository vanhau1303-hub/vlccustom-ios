import Foundation
import MobileVLCKit

/// Wires libVLC's own internal logging into a file, and adds our own proxy/player lifecycle lines to the same
/// file — real evidence (the exact demux/decoder/access-module error, or a network failure) instead of guessing
/// from a generic on-screen message. Exportable from Cài đặt via `ShareLink`.
enum PlaybackDiagnostics {
    static let logURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("vlc_diagnostics.log")
    }()

    private static var fileLogger: VLCFileLogger?
    /// One O_APPEND descriptor shared by libVLC's logger and our own lines. Two separately-seeked handles (as before)
    /// overwrote each other's lines, which is why app lines went missing from shared logs.
    private static var handle: FileHandle?

    /// Call once at app launch.
    static func start() {
        // Keep the file shareable: start over once it passes ~20MB.
        if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? NSNumber,
           size.int64Value > 20_000_000 {
            try? FileManager.default.removeItem(at: logURL)
        }
        let fd = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.handle = handle
        let logger = VLCFileLogger(fileHandle: handle)
        // Info, not debug: libVLC's debug output is thousands of lines per minute of playback, and writing all of it
        // to disk on the decoding threads costs smoothness. Errors/warnings (codec, network) are still all there.
        logger.level = .info
        VLCLibrary.shared().loggers = [logger]
        fileLogger = logger
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        append("=== app start v\(version), iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func clear() {
        writeQueue.async {
            if let handle { try? handle.truncate(atOffset: 0) }
        }
    }

    /// Appends one of our own (non-libVLC) lines — player route, SMB errors, etc. Serialized so lines never interleave.
    static func append(_ line: String) {
        // Timestamped, so a log shows how long something took (e.g. a file that is slow to start vs. stuck).
        let text = "[app] \(timeFormatter.string(from: Date())) \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        writeQueue.async {
            handle?.write(data)
        }
    }

    private static let writeQueue = DispatchQueue(label: "PlaybackDiagnostics")
}
