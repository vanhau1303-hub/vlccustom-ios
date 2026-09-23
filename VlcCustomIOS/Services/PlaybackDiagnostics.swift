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

    /// Call once at app launch.
    static func start() {
        // Keep the file shareable: start over once it passes ~20MB (libVLC debug output is verbose).
        if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? NSNumber,
           size.int64Value > 20_000_000 {
            try? FileManager.default.removeItem(at: logURL)
        }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        handle.seekToEndOfFile()
        let logger = VLCFileLogger(fileHandle: handle)
        logger.level = .debug
        VLCLibrary.shared().loggers = [logger]
        fileLogger = logger
    }

    static func clear() {
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
    }

    /// Appends one of our own (non-libVLC) lines — SMB proxy request/response, player URL resolution, etc.
    /// Called from the proxy queue, AMSMB2 threads and the main thread alike — serialized so lines never interleave.
    static func append(_ line: String) {
        let text = "[app] \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        writeQueue.async {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { handle.closeFile() }
                handle.seekToEndOfFile()
                handle.write(data)
            }
        }
    }

    private static let writeQueue = DispatchQueue(label: "PlaybackDiagnostics")
}
