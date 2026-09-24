import Foundation
import AMSMB2

/// Error shown to the user when something about the SMB connection goes wrong.
struct SmbError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One connection to an SMB2/3 server (AMSMB2, a Swift wrapper over libsmb2). AMSMB2's `SMB2Manager` is tied to a single
/// share at a time (`connectShare(name:)`, then every path is relative to that share's root, "/"), so this keeps one
/// manager per share the user has opened, all sharing the same login. An actor, so the share dictionary is safe to touch
/// from the several concurrent reads the HTTP proxy makes.
actor SmbConnection {
    nonisolated let host: String
    nonisolated let username: String
    nonisolated let password: String
    nonisolated let domain: String
    private var shareManagers: [String: Task<SMB2Manager, Error>] = [:]

    init(host: String, username: String, password: String, domain: String) {
        self.host = host
        self.username = username
        self.password = password
        self.domain = domain
    }

    // MARK: - Read gate
    //
    // The Android app hit this exact failure mode ("Failed to acquire credits in time") when concurrent SMB2 reads
    // — e.g. thumbnails generating while a video streams — outran the server's SMB2 credit window (its flow-control
    // budget for outstanding requests on one connection), and fixed it with a gate limiting concurrent reads. Doing
    // the same here for whole-file reads (`readRange`: SMB image thumbnails/viewer). Video streaming
    // (`streamContents`) deliberately does NOT take this gate: VLC opens overlapping HTTP requests for one file
    // (probe the start, jump to the index at the end, come back), and holding an exclusive slot per request
    // deadlocked those against each other. Each stream reads one chunk at a time with backpressure instead, so it
    // never floods the connection.

    private var activeReads = 0
    private var readWaiters: [CheckedContinuation<Void, Never>] = []

    /// Waits for exclusive access to read from this connection (whole-file reads only, see above).
    func acquireReadSlot() async {
        if activeReads == 0 {
            activeReads += 1
            return
        }
        await withCheckedContinuation { readWaiters.append($0) }
        activeReads += 1
    }

    func releaseReadSlot() {
        activeReads -= 1
        if !readWaiters.isEmpty {
            readWaiters.removeFirst().resume()
        }
    }

    private func credential() -> URLCredential? {
        username.isEmpty ? nil : URLCredential(user: username, password: password, persistence: .forSession)
    }

    private func baseManager() throws -> SMB2Manager {
        guard let url = URL(string: "smb://\(host)") else { throw SmbError(message: "Địa chỉ máy chủ không hợp lệ.") }
        guard let manager = SMB2Manager(url: url, domain: domain, credential: credential()) else {
            throw SmbError(message: "Không tạo được kết nối SMB.")
        }
        return manager
    }

    /// The shares on this server (skips hidden admin shares like C$).
    func listShares() async throws -> [String] {
        do {
            let manager = try baseManager()
            let shares = try await manager.listShares()
            return shares.map(\.name).filter { !$0.hasSuffix("$") }
        } catch {
            throw SmbError(message: Self.friendlyMessage(error))
        }
    }

    /// One connected manager per share. Stored as a Task so concurrent first callers (the player's first request
    /// and a thumbnail, say) share one connect instead of racing to open two.
    private func managerFor(share: String) async throws -> SMB2Manager {
        if let existing = shareManagers[share] {
            do { return try await existing.value } catch { shareManagers[share] = nil }
        }
        let base = try baseManager()
        let task = Task { () throws -> SMB2Manager in
            try await base.connectShare(name: share)
            return base
        }
        shareManagers[share] = task
        do {
            return try await task.value
        } catch {
            shareManagers[share] = nil
            throw SmbError(message: Self.friendlyMessage(error))
        }
    }

    /// Runs `body` on the share's manager, and if it fails, reconnects the share once and tries again — Windows
    /// drops idle SMB sessions (and iOS drops sockets while the app sits in the background), after which the cached
    /// manager fails every call until it is replaced.
    private func withManager<T>(share: String, _ body: (SMB2Manager) async throws -> T) async throws -> T {
        let manager = try await managerFor(share: share)
        do {
            return try await body(manager)
        } catch {
            shareManagers[share] = nil
            let fresh = try await managerFor(share: share)
            return try await body(fresh)
        }
    }

    /// Entries of "share/sub/folder" ("" lists the shares themselves, via `listShares`).
    func list(path: String) async throws -> [SmbEntry] {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty {
            let shares = try await listShares()
            return shares.map { SmbEntry(name: $0, path: $0, isDirectory: true, sizeBytes: 0, lastModified: .distantPast) }
        }
        let (share, relative) = Self.split(trimmed)
        do {
            let items = try await withManager(share: share) { manager in
                try await manager.contentsOfDirectory(atPath: relative.isEmpty ? "/" : "/" + relative)
            }
            let entries: [SmbEntry] = items.compactMap { info in
                guard let name = info[.nameKey] as? String, name != ".", name != ".." else { return nil }
                if name.hasSuffix("$") { return nil }
                let isDir = (info[.fileResourceTypeKey] as? URLFileResourceType) == .directory
                let size = Self.int64(info[.fileSizeKey])
                let modified = (info[.contentModificationDateKey] as? Date) ?? .distantPast
                let childPath = relative.isEmpty ? "\(share)/\(name)" : "\(share)/\(relative)/\(name)"
                return SmbEntry(name: name, path: childPath, isDirectory: isDir, sizeBytes: size, lastModified: modified)
            }
            return entries.sorted { a, b in
                a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        } catch {
            throw SmbError(message: Self.friendlyMessage(error))
        }
    }

    /// Size of "share/path/file.ext".
    func fileSize(path: String) async throws -> Int64 {
        let (share, relative) = Self.split(path)
        do {
            let attrs = try await withManager(share: share) { manager in
                try await manager.attributesOfItem(atPath: "/" + relative)
            }
            return Self.int64(attrs[.fileSizeKey])
        } catch {
            throw SmbError(message: Self.friendlyMessage(error))
        }
    }

    /// Reads `count` bytes at `offset` from "share/path/file.ext" — one call, one open/close of the remote file.
    /// Fine for isolated reads (a thumbnail, a whole small image); for a long sequential read (video playback) use
    /// `streamContents` instead.
    func readRange(path: String, offset: Int64, count: Int) async throws -> Data {
        let (share, relative) = Self.split(path)
        let range: Range<Int64> = offset..<(offset + Int64(count))
        await acquireReadSlot()
        defer { releaseReadSlot() }
        do {
            return try await withManager(share: share) { (manager) -> Data in
                try await manager.contents(atPath: "/" + relative, range: range)
            }
        } catch {
            throw SmbError(message: Self.friendlyMessage(error))
        }
    }

    /// Reads "share/path/file.ext" sequentially from `offset`, opening the remote file once, handing each chunk
    /// (AMSMB2's max read size, typically 1–8MB) to `onChunk` **synchronously on AMSMB2's worker thread**. Reading
    /// stops as soon as `onChunk` returns `false`, so the caller controls both backpressure (block inside `onChunk`
    /// until the chunk has been delivered) and cancellation (return `false` once the HTTP client went away).
    ///
    /// Deliberately NOT AMSMB2's `contents(atPath:range:) -> AsyncThrowingStream` (used up to v0.8): that one
    /// buffers without bound and never checks whether anyone is still listening, so every HTTP request VLC or
    /// AVFoundation abandoned (they drop the connection on every seek/probe) kept reading the *entire rest of the
    /// file* over SMB in the background — and with the v0.7 read gate held for that whole zombie read, the
    /// player's next request waited behind it forever. That was the real reason SMB videos never started.
    func streamContents(path: String, from offset: Int64, onChunk: @Sendable @escaping (Data) -> Bool) async throws {
        let (share, relative) = Self.split(path)
        let manager = try await managerFor(share: share)
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                manager.contents(
                    atPath: "/" + relative, offset: offset,
                    fetchedData: { _, _, data in onChunk(data) },
                    completionHandler: { error in
                        if let error { cont.resume(throwing: error) } else { cont.resume() }
                    }
                )
            }
        } catch {
            throw SmbError(message: Self.friendlyMessage(error))
        }
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let v = value as? Int64 { return v }
        if let v = value as? NSNumber { return v.int64Value }
        if let v = value as? Int { return Int64(v) }
        return 0
    }

    private static func split(_ path: String) -> (share: String, relative: String) {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : "")
    }

    private static func friendlyMessage(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("auth") || text.localizedCaseInsensitiveContains("logon") || text.localizedCaseInsensitiveContains("denied") {
            return "Sai tên đăng nhập hoặc mật khẩu (hoặc tài khoản không có quyền truy cập)."
        }
        if text.localizedCaseInsensitiveContains("timed out") || text.localizedCaseInsensitiveContains("connection") || text.localizedCaseInsensitiveContains("resolve") {
            return "Không kết nối được tới máy chủ. Kiểm tra máy tính đang bật, cùng mạng Wi-Fi và đã bật chia sẻ file."
        }
        return "Lỗi SMB: \(text)"
    }
}

/// Live SMB connections, one per host, kept for the app's lifetime.
actor SmbRegistry {
    static let shared = SmbRegistry()
    private var connections: [String: SmbConnection] = [:]

    func get(_ host: String) -> SmbConnection? { connections[host.lowercased()] }

    /// Login to hand to libVLC's own SMB module for `host`: the live connection's, else the saved one.
    func login(for host: String) -> SmbPlayback.Login? {
        if let live = get(host) {
            return SmbPlayback.Login(username: live.username, password: live.password, domain: live.domain)
        }
        guard let profile = SmbServerStore.load().first(where: { $0.host.lowercased() == host.lowercased() }) else { return nil }
        return SmbPlayback.Login(username: profile.username, password: SmbServerStore.password(for: profile.host), domain: profile.domain)
    }

    /// The live connection for `host`, or a fresh one from the saved login — so a video opened from Playlist or
    /// Yêu thích still plays when the user has not browsed to that server yet since launching the app.
    func getOrReconnect(_ host: String) async -> SmbConnection? {
        if let existing = get(host) { return existing }
        guard let profile = SmbServerStore.load().first(where: { $0.host.lowercased() == host.lowercased() }) else { return nil }
        return try? await connect(host: profile.host, username: profile.username,
                                  password: SmbServerStore.password(for: profile.host), domain: profile.domain)
    }

    /// Registers a login without the `listShares` check — only for the CI end-to-end hook, whose Samba server does
    /// not answer AMSMB2's share enumeration (a real Windows share does; browsing uses it).
    func registerUnchecked(host: String, username: String, password: String, domain: String) {
        connections[host.lowercased()] = SmbConnection(host: host, username: username, password: password, domain: domain)
    }

    func connect(host: String, username: String, password: String, domain: String) async throws -> SmbConnection {
        let conn = SmbConnection(host: host, username: username, password: password, domain: domain)
        _ = try await conn.listShares() // fail fast with a clear error if the login is wrong
        connections[host.lowercased()] = conn
        return conn
    }
}
