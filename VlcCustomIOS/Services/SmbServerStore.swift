import Foundation
import Security

/// Saved SMB server logins: the profile (host/username/domain) in UserDefaults, the password in the Keychain (so it is
/// encrypted at rest and tied to this device, like the Android version's encrypted preference).
enum SmbServerStore {
    private static let profilesKey = "smb_server_profiles"
    private static let service = "com.vlccustom.ios.smb"

    static func load() -> [SmbServerProfile] {
        guard let data = UserDefaults.standard.data(forKey: profilesKey) else { return [] }
        return (try? JSONDecoder().decode([SmbServerProfile].self, from: data)) ?? []
    }

    static func password(for host: String) -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func addOrUpdate(_ profile: SmbServerProfile, password: String) {
        var all = load().filter { $0.host.lowercased() != profile.host.lowercased() }
        all.insert(profile, at: 0)
        if all.count > 10 { all = Array(all.prefix(10)) }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
        savePassword(password, for: profile.host)
    }

    private static func savePassword(_ password: String, for host: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
        SecItemDelete(query as CFDictionary)
        guard !password.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
