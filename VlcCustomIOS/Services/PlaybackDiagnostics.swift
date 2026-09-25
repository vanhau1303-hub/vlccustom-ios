import Foundation
import MetricKit
import MobileVLCKit

/// The diagnostics log (Cài đặt → Chia sẻ log chẩn đoán): libVLC's own messages plus the app's lines, all written
/// through one serial queue with *throwing* file APIs.
///
/// Before, libVLC's `VLCFileLogger` and the app shared one file descriptor and the app wrote with
/// `FileHandle.write(_:)` — the old API that raises an Objective-C exception (which Swift cannot catch) when a write
/// fails. Real logs from the device stopped after 1025 bytes, i.e. the descriptor had gone bad, and every app line
/// written after that could take the whole app down. Now a failed write reopens the file instead.
enum PlaybackDiagnostics {
    static let logURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("vlc_diagnostics.log")
    }()

    private static let writeQueue = DispatchQueue(label: "PlaybackDiagnostics")
    private static var handle: FileHandle?
    private static var writesSinceSizeCheck = 0
    private static let vlcLogger = AppVLCLogger()

    /// Call once at app launch.
    static func start() {
        writeQueue.sync {
            trimIfTooBig()
            handle = openHandle()
        }
        vlcLogger.level = .info
        VLCLibrary.shared().loggers = [vlcLogger]
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        append("=== app start v\(version), iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        CrashReporter.shared.start()
    }

    static func clear() {
        writeQueue.async {
            do { try handle?.truncate(atOffset: 0) } catch { reopen() }
        }
    }

    /// One of the app's own lines, timestamped.
    static func append(_ line: String) {
        writeRaw("[app] \(timeFormatter.string(from: Date())) \(line)\n")
    }

    /// A line as is (libVLC messages come through here).
    static func writeRaw(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        writeQueue.async { write(data) }
    }

    /// Written before returning — for the moment the app is about to die (uncaught exception).
    static func writeImmediately(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        writeQueue.sync {
            write(data)
            try? handle?.synchronize()
        }
    }

    /// A complete, closed copy of the log to share.
    static func exportSnapshot() -> URL {
        writeQueue.sync { try? handle?.synchronize() }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("vlc_diagnostics_\(formatter.string(from: Date())).log")
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(at: logURL, to: copy)
        return copy
    }

    // MARK: - on writeQueue only

    private static func write(_ data: Data) {
        if handle == nil { handle = openHandle() }
        do {
            try handle?.seekToEnd()
            try handle?.write(contentsOf: data)
        } catch {
            reopen()
            try? handle?.seekToEnd()
            try? handle?.write(contentsOf: data)
        }
        writesSinceSizeCheck += 1
        if writesSinceSizeCheck >= 2_000 {
            writesSinceSizeCheck = 0
            if let size = try? handle?.offset(), size > 20_000_000 {
                try? handle?.truncate(atOffset: 0)
            }
        }
    }

    private static func reopen() {
        try? handle?.close()
        handle = openHandle()
    }

    private static func openHandle() -> FileHandle? {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        return try? FileHandle(forWritingTo: logURL)
    }

    private static func trimIfTooBig() {
        if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? NSNumber,
           size.int64Value > 20_000_000 {
            try? FileManager.default.removeItem(at: logURL)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

/// libVLC's log messages → the diagnostics log (through the same safe writer as the app's own lines).
private final class AppVLCLogger: NSObject, VLCLogging {
    var level: VLCLogLevel = .info

    func handleMessage(_ message: String, logLevel level: VLCLogLevel, context: VLCLogContext?) {
        let tag: String
        switch level {
        case .error: tag = "ERR"
        case .warning: tag = "WARN"
        case .info: tag = "INF"
        default: tag = "DBG"
        }
        PlaybackDiagnostics.writeRaw("[\(tag)] \(message)\n")
    }
}

/// Crash reports into the diagnostics log:
/// - an uncaught Objective-C exception is written (reason + stack) right before the app dies;
/// - every other crash (and long hangs) comes from iOS itself via MetricKit on the next launch, with the full call
///   stack — so "the app just closed" turns into an exact place in the code.
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()
    private let seenKey = "crash_reports_seen"

    func start() {
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.prefix(40).joined(separator: "\n")
            PlaybackDiagnostics.writeImmediately(
                "[app] !!! CRASH (exception) \(exception.name.rawValue): \(exception.reason ?? "")\n\(stack)\n")
        }
        MXMetricManager.shared.add(self)
        didReceive(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        for payload in payloads {
            let id = "\(payload.timeStampBegin.timeIntervalSince1970)-\(payload.timeStampEnd.timeIntervalSince1970)"
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            for crash in payload.crashDiagnostics ?? [] {
                let meta = crash.metaData
                let summary = "type=\(crash.exceptionType?.stringValue ?? "-") code=\(crash.exceptionCode?.stringValue ?? "-") " +
                    "signal=\(crash.signal?.stringValue ?? "-") reason=\(crash.terminationReason ?? "-") " +
                    "app=\(meta.applicationBuildVersion) os=\(meta.osVersion)"
                let stack = String(decoding: crash.callStackTree.jsonRepresentation(), as: UTF8.self)
                PlaybackDiagnostics.append("!!! CRASH (iOS report, \(payload.timeStampEnd)): \(summary)\n\(stack.prefix(12_000))")
            }
            for hang in payload.hangDiagnostics ?? [] {
                let stack = String(decoding: hang.callStackTree.jsonRepresentation(), as: UTF8.self)
                PlaybackDiagnostics.append("!!! HANG \(hang.hangDuration) (iOS report, \(payload.timeStampEnd))\n\(stack.prefix(8_000))")
            }
        }
        UserDefaults.standard.set(Array(seen.suffix(200)), forKey: seenKey)
    }
}
