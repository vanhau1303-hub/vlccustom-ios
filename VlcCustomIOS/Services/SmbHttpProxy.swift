import Foundation
import Network

/// Loopback HTTP server that streams an SMB file (with Range support), so VLCKit can play it as an ordinary HTTP URL
/// instead of depending on whatever SMB support is (or is not) built into its own network stack. Mirrors the same idea
/// used in the Android and Windows versions of this app.
final class SmbHttpProxy {
    static let shared = SmbHttpProxy()

    private var listener: NWListener?
    private var port: NWEndpoint.Port = 0
    private let queue = DispatchQueue(label: "SmbHttpProxy")

    private init() {}

    /// Starts the server the first time it is needed; safe to call repeatedly.
    private func ensureStarted() throws {
        if listener != nil { return }
        var lastError: Error?
        for candidate in UInt16(38471)...38571 {
            do {
                let params = NWParameters.tcp
                let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: candidate)!)
                listener.newConnectionHandler = { [weak self] connection in
                    connection.start(queue: self?.queue ?? .main)
                    self?.handle(connection)
                }
                listener.start(queue: queue)
                self.listener = listener
                self.port = NWEndpoint.Port(rawValue: candidate)!
                return
            } catch {
                lastError = error
            }
        }
        throw SmbError(message: "Không mở được cổng nội bộ để phát video SMB. \(lastError?.localizedDescription ?? "")")
    }

    /// URL to hand to VLCKit for "share/path/file.ext" on `host`.
    func url(host: String, path: String) throws -> URL {
        try ensureStarted()
        let name = (path as NSString).lastPathComponent
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port.rawValue)
        components.path = "/\(name)"
        components.queryItems = [URLQueryItem(name: "h", value: host), URLQueryItem(name: "p", value: path)]
        guard let url = components.url else { throw SmbError(message: "Không tạo được URL phát video.") }
        return url
    }

    // MARK: - connection handling

    private func handle(_ connection: NWConnection) {
        var buffer = Data()
        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty { buffer.append(data) }
                if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = buffer[..<headerEnd.lowerBound]
                    self.respond(to: headerData, on: connection)
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    receiveMore()
                }
            }
        }
        receiveMore()
    }

    private func respond(to headerData: Data, on connection: NWConnection) {
        let text = String(data: headerData, encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { close(connection, status: 400); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { close(connection, status: 400); return }
        let method = String(parts[0])
        let target = String(parts[1])

        var rangeHeader: String?
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("range:") {
                rangeHeader = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
            }
        }

        guard let query = target.split(separator: "?", maxSplits: 1).last else { close(connection, status: 400); return }
        let params = Self.parseQuery(String(query))
        guard let host = params["h"], let path = params["p"] else { close(connection, status: 404); return }

        Task {
            guard let smb = await SmbRegistry.shared.get(host) else { close(connection, status: 404); return }

            let length: Int64
            do {
                length = try await smb.fileSize(path: path)
            } catch {
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
                    if !bounds[0].isEmpty { start = Int64(bounds[0]) ?? 0 }
                    if !bounds[1].isEmpty { end = Int64(bounds[1]) ?? end }
                    else if bounds[0].isEmpty, let suffix = Int64(bounds[1]) { start = max(0, length - suffix) }
                    partial = true
                }
            }
            end = min(end, length - 1)
            let contentLength = max(0, end - start + 1)

            var head = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\n"
            head += "Content-Type: application/octet-stream\r\n"
            head += "Accept-Ranges: bytes\r\n"
            head += "Content-Length: \(contentLength)\r\n"
            if partial { head += "Content-Range: bytes \(start)-\(end)/\(length)\r\n" }
            head += "Connection: close\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

            if method == "HEAD" || contentLength == 0 { close(connection, status: nil); return }

            do {
                let stream = try await smb.readStream(path: path, range: start..<(end + 1))
                for try await chunk in stream where !chunk.isEmpty {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        connection.send(content: chunk, completion: .contentProcessed { _ in cont.resume() })
                    }
                }
            } catch {
                // Streaming failed partway through (server dropped, seek elsewhere) — headers are already sent, so
                // there is nothing left to do but stop; the player will surface this as a playback error.
            }
            close(connection, status: nil)
        }
    }

    private func close(_ connection: NWConnection, status: Int?) {
        if let status {
            let head = "HTTP/1.1 \(status) Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in connection.cancel() })
        } else {
            connection.cancel()
        }
    }

    private static func parseQuery(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in query.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            result[String(kv[0]).removingPercentEncoding ?? String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
        }
        return result
    }
}
