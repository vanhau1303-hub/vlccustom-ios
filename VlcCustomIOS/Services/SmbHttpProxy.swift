import Foundation
import Network
import UniformTypeIdentifiers

/// Loopback HTTP server that streams an SMB file (with Range support), so VLCKit (and AVFoundation, for thumbnails)
/// can play it as an ordinary HTTP URL instead of depending on whatever SMB support is (or is not) built into its own
/// network stack. Mirrors the same idea used in the Android and Windows versions of this app.
///
/// Each HTTP request is served by its own sequential SMB read that stops the moment the client disconnects (players
/// drop and reopen connections on every seek) and only reads the next chunk once the previous one was handed to the
/// socket — see `SmbConnection.streamContents` for what went wrong before this.
final class SmbHttpProxy {
    static let shared = SmbHttpProxy()

    private var listener: NWListener?
    private var port: NWEndpoint.Port = 0
    private let queue = DispatchQueue(label: "SmbHttpProxy")
    private let startLock = NSLock()

    /// URL token → (host, path). The URL carries only an opaque token plus the file name (for the extension VLC
    /// uses as a demuxer hint), so SMB paths with "&", "+", "#", "%" or Vietnamese characters never have to survive
    /// a round-trip through URL encoding inside libVLC.
    private var targets: [String: (host: String, path: String, background: Bool)] = [:]
    /// Open connections serving background work (thumbnails), cut off the moment a video opens.
    private var backgroundConnections: [ObjectIdentifier: NWConnection] = [:]
    /// File sizes remembered for a minute (like the Android proxy): every seek used to cost an extra SMB round trip.
    private var sizeCache: [String: (size: Int64, at: Date)] = [:]
    private var tokensByKey: [String: String] = [:]
    private let targetsLock = NSLock()

    private init() {}

    /// Starts the server the first time it is needed (and again if iOS tore the socket down while the app was
    /// suspended); safe to call repeatedly. Waits until the listener is actually accepting connections — handing VLC
    /// a URL before that made its very first connect get refused.
    private func ensureStarted() throws {
        startLock.lock()
        defer { startLock.unlock() }
        if listener != nil { return }
        var lastError: Error?
        for candidate in UInt16(38471)...38571 {
            guard let nwPort = NWEndpoint.Port(rawValue: candidate) else { continue }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let newListener: NWListener
            do {
                newListener = try NWListener(using: params, on: nwPort)
            } catch {
                lastError = error
                continue
            }
            let ready = DispatchSemaphore(value: 0)
            let outcome = StartOutcome()
            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                switch state {
                case .ready:
                    outcome.set(ok: true)
                    ready.signal()
                case .failed(let error):
                    PlaybackDiagnostics.append("proxy: listener failed: \(error)")
                    if !outcome.isSet {
                        outcome.set(ok: false, error: error)
                        ready.signal()
                    }
                    newListener?.cancel()
                    self?.listenerDied(newListener)
                case .cancelled:
                    self?.listenerDied(newListener)
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.queue)
                self.handle(connection)
            }
            newListener.start(queue: queue)
            if ready.wait(timeout: .now() + 3) == .timedOut {
                newListener.cancel()
                lastError = SmbError(message: "timeout")
                continue
            }
            if outcome.ok {
                listener = newListener
                port = nwPort
                PlaybackDiagnostics.append("proxy: listening on 127.0.0.1:\(candidate)")
                return
            }
            lastError = outcome.error
        }
        throw SmbError(message: "Không mở được cổng nội bộ để phát video SMB. \(lastError?.localizedDescription ?? "")")
    }

    /// Hopped off the proxy queue: `ensureStarted` holds `startLock` while waiting for a listener's state callback
    /// on that queue, so taking the lock from the queue directly could deadlock.
    private func listenerDied(_ dead: NWListener?) {
        guard let dead else { return }
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            self.startLock.lock()
            if self.listener === dead { self.listener = nil }
            self.startLock.unlock()
        }
    }

    /// URL to hand to VLCKit for "share/path/file.ext" on `host`.
    /// `background`: for thumbnails — refused while a video is open and cut off when one opens.
    func url(host: String, path: String, background: Bool = false) throws -> URL {
        try ensureStarted()
        let token = token(host: host, path: path, background: background)
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        // Keep only a safe ASCII stand-in for the name: VLC needs the extension, nothing else.
        let safeName = ext.isEmpty ? "media" : "media.\(ext.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "bin")"
        guard let url = URL(string: "http://127.0.0.1:\(port.rawValue)/f/\(token)/\(safeName)") else {
            throw SmbError(message: "Không tạo được URL phát video.")
        }
        return url
    }

    private func token(host: String, path: String, background: Bool) -> String {
        targetsLock.lock()
        defer { targetsLock.unlock() }
        let key = host.lowercased() + "\n" + path + (background ? "\nbg" : "")
        if let existing = tokensByKey[key] { return existing }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        tokensByKey[key] = token
        targets[token] = (host, path, background)
        return token
    }

    /// A video just opened: drop every connection feeding a thumbnail so it gets the whole link.
    func cancelBackground() {
        targetsLock.lock()
        let open = Array(backgroundConnections.values)
        backgroundConnections.removeAll()
        targetsLock.unlock()
        if !open.isEmpty { PlaybackDiagnostics.append("proxy: video opened — cancelling \(open.count) thumbnail stream(s)") }
        open.forEach { $0.cancel() }
    }

    private func track(_ connection: NWConnection, background: Bool) {
        guard background else { return }
        targetsLock.lock(); backgroundConnections[ObjectIdentifier(connection)] = connection; targetsLock.unlock()
    }

    private func untrack(_ connection: NWConnection) {
        targetsLock.lock(); backgroundConnections[ObjectIdentifier(connection)] = nil; targetsLock.unlock()
    }

    private func cachedSize(_ key: String) -> Int64? {
        targetsLock.lock(); defer { targetsLock.unlock() }
        guard let entry = sizeCache[key], Date().timeIntervalSince(entry.at) < 60 else { return nil }
        return entry.size
    }

    private func rememberSize(_ key: String, _ size: Int64) {
        targetsLock.lock(); sizeCache[key] = (size, Date()); targetsLock.unlock()
    }

    private func target(for token: String) -> (host: String, path: String, background: Bool)? {
        targetsLock.lock()
        defer { targetsLock.unlock() }
        return targets[token]
    }

    // MARK: - connection handling

    private func handle(_ connection: NWConnection) {
        var buffer = Data()
        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
                guard let self else { connection.cancel(); return }
                if let data, !data.isEmpty { buffer.append(data) }
                if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = buffer[..<headerEnd.lowerBound]
                    self.respond(to: Data(headerData), on: connection)
                } else if isComplete || error != nil || buffer.count > 64 * 1024 {
                    connection.cancel()
                } else {
                    receiveMore()
                }
            }
        }
        receiveMore()
    }

    private func respond(to headerData: Data, on connection: NWConnection) {
        let text = String(decoding: headerData, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { close(connection, status: 400); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { close(connection, status: 400); return }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var rangeHeader: String?
        for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
            rangeHeader = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
        }

        // "/f/<token>/<name>"
        let segments = target.split(separator: "?", maxSplits: 1)[0].split(separator: "/")
        guard segments.count >= 2, segments[0] == "f", let resolved = self.target(for: String(segments[1])) else {
            PlaybackDiagnostics.append("proxy: unknown target \(target) — 404")
            close(connection, status: 404)
            return
        }
        let host = resolved.host
        let path = resolved.path
        if resolved.background && ThumbnailPolicy.shared.videoOpen {
            close(connection, status: 503)
            return
        }
        track(connection, background: resolved.background)

        PlaybackDiagnostics.append("proxy: \(method) \(path) range=\(rangeHeader ?? "-")")

        let state = ClientState()
        connection.stateUpdateHandler = { newState in
            switch newState {
            case .failed, .cancelled: state.markGone()
            default: break
            }
        }

        Task {
            guard let smb = await SmbRegistry.shared.getOrReconnect(host) else {
                PlaybackDiagnostics.append("proxy: no SMB connection for host \(host) — 404")
                close(connection, status: 404)
                return
            }

            let sizeKey = host.lowercased() + "\n" + path
            let length: Int64
            do {
                if let known = self.cachedSize(sizeKey) {
                    length = known
                } else {
                    length = try await smb.fileSize(path: path)
                    self.rememberSize(sizeKey, length)
                }
            } catch {
                PlaybackDiagnostics.append("proxy: fileSize failed for \(path): \(error.localizedDescription) — 500")
                close(connection, status: 500)
                return
            }

            var start: Int64 = 0
            var end: Int64 = length - 1
            var partial = false
            if let rangeHeader, let match = rangeHeader.range(of: #"bytes=(\d*)-(\d*)"#, options: .regularExpression) {
                let spec = String(rangeHeader[match]).replacingOccurrences(of: "bytes=", with: "")
                let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
                if bounds.count == 2 {
                    if bounds[0].isEmpty, let suffix = Int64(bounds[1]) {
                        start = max(0, length - suffix)
                    } else {
                        start = Int64(bounds[0]) ?? 0
                        if !bounds[1].isEmpty { end = Int64(bounds[1]) ?? end }
                    }
                    partial = true
                }
            }
            end = min(end, length - 1)

            if partial && (start >= length || start > end) {
                let head = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(length)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
                PlaybackDiagnostics.append("proxy: 416 for range \(rangeHeader ?? "") (length \(length))")
                return
            }
            let contentLength = max(0, end - start + 1)

            var head = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\n"
            head += "Content-Type: \(Self.mimeType(for: path))\r\n"
            head += "Accept-Ranges: bytes\r\n"
            head += "Content-Length: \(contentLength)\r\n"
            if partial { head += "Content-Range: bytes \(start)-\(end)/\(length)\r\n" }
            head += "Connection: close\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            PlaybackDiagnostics.append("proxy: \(partial ? "206" : "200") length=\(length) contentLength=\(contentLength) [\(start)-\(end)]")

            if method == "HEAD" || contentLength == 0 { self.finish(connection); return }

            let remaining = Counter(contentLength)
            let sent = Counter(0)
            do {
                // Quick first answer (like the Android proxy): a small read goes out right away, instead of the
                // client waiting for a whole read-size block (up to 8 MB on Windows) after every seek — players
                // that jump around a file (fragmented / non-interleaved MP4) seek hundreds of times.
                let firstCount = Int(min(Int64(256 * 1024), contentLength))
                let first = try await smb.readChunk(path: path, offset: start, count: firstCount)
                if !first.isEmpty, !state.isGone {
                    let delivered = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                        connection.send(content: first, completion: .contentProcessed { error in cont.resume(returning: error == nil) })
                    }
                    if delivered {
                        remaining.value -= Int64(first.count)
                        sent.value += Int64(first.count)
                    } else {
                        state.markGone()
                    }
                }
                if remaining.value > 0, !state.isGone {
                try await smb.streamContents(path: path, from: start + sent.value) { chunk in
                    // Runs synchronously on AMSMB2's worker thread: blocking here until the socket took the chunk is
                    // the backpressure, and returning false is how the read stops.
                    if state.isGone || chunk.isEmpty { return false }
                    let slice = chunk.count > remaining.value ? chunk.prefix(Int(remaining.value)) : chunk
                    let delivered = DispatchSemaphore(value: 0)
                    let ok = Counter(1)
                    connection.send(content: slice, completion: .contentProcessed { error in
                        if error != nil { ok.value = 0; state.markGone() }
                        delivered.signal()
                    })
                    if delivered.wait(timeout: .now() + 60) == .timedOut {
                        state.markGone()
                        return false
                    }
                    guard ok.value == 1 else { return false }
                    remaining.value -= Int64(slice.count)
                    sent.value += Int64(slice.count)
                    return remaining.value > 0 && !state.isGone
                }
                }
                PlaybackDiagnostics.append("proxy: done, sent \(sent.value)/\(contentLength) bytes\(state.isGone ? " (client closed)" : "")")
            } catch {
                PlaybackDiagnostics.append("proxy: SMB read error after \(sent.value)/\(contentLength) bytes: \(error.localizedDescription)")
            }
            self.untrack(connection)
            self.finish(connection)
        }
    }

    /// Ends the response once everything queued has been flushed.
    private func finish(_ connection: NWConnection) {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func close(_ connection: NWConnection, status: Int) {
        untrack(connection)
        let head = "HTTP/1.1 \(status) Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    /// A real media type — AVFoundation (thumbnails) refuses an HTTP resource served as application/octet-stream.
    private static func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "mkv": return "video/x-matroska"
        case "mka": return "audio/x-matroska"
        case "ts", "m2ts", "mts": return "video/mp2t"
        default:
            return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}

// Small thread-safe boxes shared between the proxy queue and AMSMB2's worker thread.

private final class ClientState: @unchecked Sendable {
    private let lock = NSLock()
    private var gone = false
    var isGone: Bool { lock.lock(); defer { lock.unlock() }; return gone }
    func markGone() { lock.lock(); gone = true; lock.unlock() }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int64
    init(_ value: Int64) { _value = value }
    var value: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

private final class StartOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var _set = false
    private var _ok = false
    private var _error: Error?
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return _set }
    var ok: Bool { lock.lock(); defer { lock.unlock() }; return _ok }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return _error }
    func set(ok: Bool, error: Error? = nil) { lock.lock(); _set = true; _ok = ok; _error = error; lock.unlock() }
}
