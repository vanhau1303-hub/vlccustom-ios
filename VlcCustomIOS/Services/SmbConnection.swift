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
    private let username: String
    private let password: String
    private let domain: String
    private var shareManagers: [String: SMB2Manager] = [:]

    init(host: String, username: String, password: String, domain: String) {
        self.host = host
        self.username = username
        self.password = password
        self.domain = domain
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

    private func managerFor(share: String) async throws -> SMB2Manager {
        if let existing = shareManagers[share] { return existing }
        do {
            let manager = try baseManager()
            try await manager.connectShare(name: share)
            shareManagers[share] = manager
            return manager
        } catch {
            throw SmbError(message: Self.friendlyMessage(error))
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
        let manager = try await managerFor(share: share)
        do {
            let items = try await manager.contentsOfDirectory(atPath: relative.isEmpty ? "/" : "/" + relative)
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
        let manager = try await managerFor(share: share)
        do {
            let attrs = try await manager.attributesOfItem(atPath: "/" + relative)
            return Self.int64(attrs[.fileSizeKey])
        } catch {
            throw SmbError(message: Self.friendlyMessage(error))
        }
    }

    /// Reads `count` bytes at `offset` from "share/path/file.ext".
    func readRange(path: String, offset: Int64, count: Int) async throws -> Data {
        let (share, relative) = Self.split(path)
        let manager = try await managerFor(share: share)
        let range: Range<Int64> = offset..<(offset + Int64(count))
        do {
            return try await manager.contents(atPath: "/" + relative, range: range)
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

    func connect(host: String, username: String, password: String, domain: String) async throws -> SmbConnection {
        let conn = SmbConnection(host: host, username: username, password: password, domain: domain)
        _ = try await conn.listShares() // fail fast with a clear error if the login is wrong
        connections[host.lowercased()] = conn
        return conn
    }
}
