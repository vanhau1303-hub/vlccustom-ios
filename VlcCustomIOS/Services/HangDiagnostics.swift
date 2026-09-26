import Foundation
import MachO
import MobileVLCKit

/// Keeps the main thread free of libVLC locks VLCKit itself takes, and makes freezes diagnosable.
enum HangDiagnostics {
    static func start() {
        installNonBlockingIsPlaying()
        logBinaries()
        MainThreadWatchdog.shared.start()
    }

    /// VLCKit calls `-[VLCMediaPlayer isPlaying]` on the main thread for *every* state change (to set the idle
    /// timer) — and `isPlaying` is `libvlc_media_player_is_playing`, which takes libVLC's player lock. A broken file
    /// fires dozens of buffering state changes a second (see the freeze log), each one a main-thread wait on a lock
    /// the decoding threads also use. Answered from VLCKit's cached, event-driven state instead.
    private static func installNonBlockingIsPlaying() {
        let selector = NSSelectorFromString("isPlaying")
        guard let method = class_getInstanceMethod(VLCMediaPlayer.self, selector) else { return }
        let block: @convention(block) (VLCMediaPlayer) -> Bool = { player in player.isActive }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// UUID → file name of every loaded binary (app, MobileVLCKit, system frameworks).
    static let binaryNames: [String: String] = {
        var map: [String: String] = [:]
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index), let rawName = _dyld_get_image_name(index) else { continue }
            let name = (String(cString: rawName) as NSString).lastPathComponent
            var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<header.pointee.ncmds {
                let load = command.assumingMemoryBound(to: load_command.self).pointee
                if load.cmd == UInt32(LC_UUID) {
                    let uuid = command.assumingMemoryBound(to: uuid_command.self).pointee.uuid
                    map[UUID(uuid: uuid).uuidString] = name
                    break
                }
                command = command.advanced(by: Int(load.cmdsize))
            }
        }
        return map
    }()

    /// The app's own binaries in the log at every launch, so a crash report from this build can be mapped.
    private static func logBinaries() {
        let ours = binaryNames.filter { ["VlcCustomIOS", "MobileVLCKit", "AMSMB2", "WhisperKit"].contains($0.value) }
        PlaybackDiagnostics.append("binaries: " + ours.map { "\($0.value)=\($0.key)" }.sorted().joined(separator: " "))
    }

    /// MetricKit call-stack tree → readable text: per thread, innermost frame first, as "binary +offset".
    static func readable(_ treeJSON: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: treeJSON) as? [String: Any],
              let stacks = root["callStacks"] as? [[String: Any]] else { return "(call stack unreadable)" }
        var out: [String] = []
        for (index, stack) in stacks.enumerated() {
            let attributed = stack["threadAttributed"] as? Bool ?? false
            var chain: [String] = []
            var frames = stack["callStackRootFrames"] as? [[String: Any]] ?? []
            while let frame = frames.first {
                let uuid = frame["binaryUUID"] as? String ?? "?"
                let offset = frame["offsetIntoBinaryTextSegment"] as? Int ?? 0
                let name = frame["binaryName"] as? String ?? binaryNames[uuid] ?? "?\(uuid.prefix(8))"
                chain.append("\(name) +\(offset)")
                frames = frame["subFrames"] as? [[String: Any]] ?? []
            }
            guard !chain.isEmpty else { continue }
            out.append("  thread \(index)\(attributed ? " (the one that hung/crashed)" : ""):")
            out.append(contentsOf: chain.reversed().prefix(40).map { "    " + $0 })
        }
        return out.joined(separator: "\n")
    }
}

/// Notices when the main thread stops responding (> 3 s) and writes it to the log with what the player was doing,
/// then how long it lasted — a freeze leaves a trace even when iOS kills the app before any crash report.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()
    private let lock = NSLock()
    private var lastPong = Date()
    private var stalledSince: Date?
    private let queue = DispatchQueue(label: "MainThreadWatchdog", qos: .utility)

    func start() {
        tick()
    }

    private func tick() {
        DispatchQueue.main.async { [self] in
            lock.lock(); lastPong = Date(); lock.unlock()
        }
        queue.asyncAfter(deadline: .now() + 1) { [self] in
            lock.lock()
            let silence = Date().timeIntervalSince(lastPong)
            let since = stalledSince
            lock.unlock()
            if silence > 3, since == nil {
                lock.lock(); stalledSince = Date().addingTimeInterval(-silence); lock.unlock()
                PlaybackDiagnostics.append("!!! MAIN THREAD STALLED (no response for \(Int(silence))s) — last: \(PlayerTrace.last)")
            } else if silence < 1.5, let since {
                lock.lock(); stalledSince = nil; lock.unlock()
                PlaybackDiagnostics.append("main thread responsive again after \(String(format: "%.1f", Date().timeIntervalSince(since)))s")
            }
            tick()
        }
    }
}

/// The latest player event, for the stall message.
enum PlayerTrace {
    private static let lock = NSLock()
    private static var value = "-"
    static var last: String {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
