import Foundation
import AMSMB2

/// Error shown to the user when something about the SMB connection goes wrong.
struct SmbError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One connection to an SMB2/3 server (AMSMB2, a Swift wrapper over libsmb2). One `SMB2Manager` per host; AMSMB2 itself
/// manages the underlying share connections and read/write queueing.
final class SmbConnection {
    let host: String
    private let manager: SMB2Manager

    init(host: String, username: String, password: String, domain: String) throws {
        self.host = host
        guard let url = URL(string: "smb://\(host)") else { throw SmbError(message: "Địa chỉ máy chủ không hợp lệ.") }
        let credential = URLCredential(user: domain.isEmpty ? username : "\(domain)\\\(username)", password: password, persistence: .forSession)
        guard let manager = SMB2Manager(url: url, credential: username.isEmpty ? nil : credential) else {
            throw SmbError(message: "Không tạo được kết nối SMB.")
        }
        self.manager = manager
    }

    /// The shares on this server (skips hidden admin shares like C$).
    func listShares() async throws -> [String] {
        try await withCheckedThrowingContinuation { cont in
            manager.listShares { result in
                switch result {
                case .success(let shares):
                    cont.resume(returning: shares.map(\.name).filter { !$0.hasSuffix("$") })
                case .failure(let error):
                    cont.resume(throwing: SmbError(message: Self.friendlyMessage(error)))
                }
            }
        }
    }

    /// Entries of "share/sub/folder" ("" lists the shares themselves, via `listShares`).
    func list(path: String) async throws -> [SmbEntry] {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty {
            let shares = try await listShares()
            return shares.map { SmbEntry(name: $0, path: $0, isDirectory: true, sizeBytes: 0, lastModified: .distantPast) }
        }
        let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        let share = parts[0]
        let relative = parts.count > 1 ? parts[1] : ""

        return try await withCheckedThrowingContinuation { cont in
            manager.contentsOfDirectory(atPath: relative, onShare: share) { result in
                switch result {
                case .success(let items):
                    let entries: [SmbEntry] = items.compactMap { info in
                        guard let name = info[.nameKey] as? String, name != ".", name != ".." else { return nil }
                        if name.hasSuffix("$") { return nil } // drop hidden admin-style shares/files
                        let isDir = (info[.fileResourceTypeKey] as? URLFileResourceType) == .directory
                        let size = (info[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
                        let modified = (info[.contentModificationDateKey] as? Date) ?? .distantPast
                        let childPath = relative.isEmpty ? "\(share)/\(name)" : "\(share)/\(relative)/\(name)"
                        return SmbEntry(name: name, path: childPath, isDirectory: isDir, sizeBytes: size, lastModified: modified)
                    }
                    let sorted = entries.sorted { a, b in
                        a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                    }
                    cont.resume(returning: sorted)
                case .failure(let error):
                    cont.resume(throwing: SmbError(message: Self.friendlyMessage(error)))
                }
            }
        }
    }

    /// Size of "share/path/file.ext".
    func fileSize(path: String) async throws -> Int64 {
        let (share, relative) = Self.split(path)
        return try await withCheckedThrowingContinuation { cont in
            manager.attributesOfItem(atPath: relative, onShare: share) { result in
                switch result {
                case .success(let attrs):
                    cont.resume(returning: (attrs[.fileSizeKey] as? NSNumber)?.int64Value ?? 0)
                case .failure(let error):
                    cont.resume(throwing: SmbError(message: Self.friendlyMessage(error)))
                }
            }
        }
    }

    /// Reads `count` bytes at `offset` from "share/path/file.ext".
    func readRange(path: String, offset: Int64, count: Int) async throws -> Data {
        let (share, relative) = Self.split(path)
        let range: Range<Int64> = offset..<(offset + Int64(count))
        return try await withCheckedThrowingContinuation { cont in
            manager.contents(atPath: relative, onShare: share, range: range, progress: nil) { result in
                switch result {
                case .success(let data): cont.resume(returning: data)
                case .failure(let error): cont.resume(throwing: SmbError(message: Self.friendlyMessage(error)))
                }
            }
        }
    }

    private static func split(_ path: String) -> (share: String, relative: String) {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : "")
    }

    private static func friendlyMessage(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("auth") {
            return "Sai tên đăng nhập hoặc mật khẩu (hoặc tài khoản không có quyền truy cập)."
        }
        if text.localizedCaseInsensitiveContains("timed out") || text.localizedCaseInsensitiveContains("connection") {
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
        let conn = try SmbConnection(host: host, username: username, password: password, domain: domain)
        _ = try await conn.listShares() // fail fast with a clear error if the login is wrong
        connections[host.lowercased()] = conn
        return conn
    }
}
