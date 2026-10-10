import Foundation
import Security
import SwiftUI

/// The user's own (free) OpenSubtitles.com account: downloads then count against their daily allowance instead of
/// the small one shared by everybody without a login. Username in UserDefaults, password in the Keychain, the
/// session token in memory (renewed with the saved password when it expires).
@MainActor
final class OpenSubtitlesAccount: ObservableObject {
    static let shared = OpenSubtitlesAccount()
    private static let usernameKey = "opensubtitles_username"

    @Published private(set) var username: String
    /// Downloads left today, as last reported by OpenSubtitles.
    @Published private(set) var remaining: Int?
    @Published private(set) var allowance: Int?
    @Published private(set) var busy = false
    @Published var message: String?

    private var cachedToken: String?

    var isLoggedIn: Bool { !username.isEmpty }

    private init() {
        username = UserDefaults.standard.string(forKey: Self.usernameKey) ?? ""
    }

    /// A session token for downloads, logging in again with the saved password when needed.
    func token() async -> String? {
        if let cachedToken { return cachedToken }
        guard isLoggedIn, let password = KeychainItem.read(account: "password") else { return nil }
        do {
            let session = try await OpenSubtitles.login(username: username, password: password)
            cachedToken = session.token
            allowance = session.allowance
            return session.token
        } catch {
            PlaybackDiagnostics.append("opensubtitles: login failed — \(error.localizedDescription)")
            return nil
        }
    }

    func logIn(username: String, password: String) async {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !password.isEmpty else {
            message = "Nhập tên đăng nhập và mật khẩu OpenSubtitles."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let session = try await OpenSubtitles.login(username: name, password: password)
            cachedToken = session.token
            allowance = session.allowance
            self.username = name
            UserDefaults.standard.set(name, forKey: Self.usernameKey)
            KeychainItem.write(password, account: "password")
            message = session.allowance.map { "Đã đăng nhập — \($0) lượt tải mỗi ngày." } ?? "Đã đăng nhập."
        } catch {
            message = error.localizedDescription
        }
    }

    func logOut() {
        username = ""
        cachedToken = nil
        remaining = nil
        allowance = nil
        UserDefaults.standard.removeObject(forKey: Self.usernameKey)
        KeychainItem.delete(account: "password")
        message = nil
    }

    func dropToken() { cachedToken = nil }

    func noteRemaining(_ count: Int) { remaining = count }

    /// Test builds without a built-in key: one typed in Cài đặt → Phụ đề.
    nonisolated static var typedApiKey: String { KeychainItem.read(account: "api-key") ?? "" }

    static func setTypedApiKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { KeychainItem.delete(account: "api-key") } else { KeychainItem.write(trimmed, account: "api-key") }
    }
}

extension OpenSubtitles {
    struct Session {
        let token: String
        let allowance: Int?
    }

    /// POST /login with the user's own account.
    static func login(username: String, password: String) async throws -> Session {
        guard !apiKey.isEmpty else { throw Failure(message: "Bản này chưa có khoá OpenSubtitles.") }
        var request = URLRequest(url: URL(string: "https://api.opensubtitles.com/api/v1/login")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        request.setValue("LANPlayer v\(version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 { throw Failure(message: "Sai tên đăng nhập hoặc mật khẩu OpenSubtitles.") }
            let text = json?["message"] as? String
            throw Failure(message: text.map { "OpenSubtitles: \($0)" } ?? "Đăng nhập OpenSubtitles lỗi \(http.statusCode).")
        }
        guard let token = json?["token"] as? String else { throw Failure(message: "OpenSubtitles không trả về phiên đăng nhập.") }
        let allowance = (json?["user"] as? [String: Any])?["allowed_downloads"] as? Int
        return Session(token: token, allowance: allowance)
    }
}

/// A string in the Keychain under LAN Player's OpenSubtitles service.
private enum KeychainItem {
    private static let service = "com.vanhau1303.lanplayer.opensubtitles"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        delete(account: account)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Cài đặt → Phụ đề → OpenSubtitles: the user's own free account (more downloads a day), and in test builds the
/// app key.
struct OpenSubtitlesAccountSection: View {
    @ObservedObject private var account = OpenSubtitlesAccount.shared
    @State private var username = ""
    @State private var password = ""
    #if SIDELOAD
    @State private var apiKey = OpenSubtitlesAccount.typedApiKey
    #endif

    var body: some View {
        Section {
            if account.isLoggedIn {
                HStack {
                    IconLabel("Đã đăng nhập: \(account.username)", systemName: "person.crop.circle.badge.checkmark", color: .green)
                    Spacer()
                    if let remaining = account.remaining {
                        Text("còn \(remaining) lượt").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Button("Đăng xuất", role: .destructive) { account.logOut() }
            } else {
                TextField("Tên đăng nhập OpenSubtitles", text: $username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Mật khẩu", text: $password)
                Button {
                    Task {
                        await account.logIn(username: username, password: password)
                        if account.isLoggedIn { password = "" }
                    }
                } label: {
                    HStack {
                        Text("Đăng nhập")
                        if account.busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(account.busy)
                if let signUp = URL(string: "https://www.opensubtitles.com/users/sign_up") {
                    Link("Tạo tài khoản miễn phí trên opensubtitles.com", destination: signUp)
                }
            }
            if let message = account.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            #if SIDELOAD
            SecureField("Khoá API OpenSubtitles (bản thử)", text: $apiKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { OpenSubtitlesAccount.setTypedApiKey(apiKey) }
                .onChange(of: apiKey) { OpenSubtitlesAccount.setTypedApiKey($0) }
            #endif
        } header: {
            Text("OpenSubtitles")
        } footer: {
            Text("Không đăng nhập vẫn tìm và tải được phụ đề, nhưng ít lượt mỗi ngày. Đăng nhập tài khoản OpenSubtitles miễn phí của bạn để có khoảng 20 lượt tải mỗi ngày. Mật khẩu được lưu trong Keychain của máy.")
        }
    }
}
