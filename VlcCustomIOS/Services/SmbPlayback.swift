import Foundation
import MobileVLCKit

/// How an SMB file is handed to VLCKit.
enum SmbPlaybackRoute: String {
    /// `smb://host/share/path` straight to libVLC's own SMB2 access module (libsmb2, built into MobileVLCKit with
    /// `--enable-smb2`), with the login passed as `smb-user`/`smb-pwd`/`smb-domain` media options — exactly how the
    /// official VLC for iOS app plays SMB shares. No loopback proxy in between.
    case direct
    /// Through `SmbHttpProxy` (AMSMB2 → loopback HTTP). Kept as the fallback if the direct route fails.
    case proxy
}

enum SmbPlayback {
    struct Login {
        let username: String
        let password: String
        let domain: String
    }

    /// RFC 3986 unreserved characters only — `CharacterSet.alphanumerics` would let Vietnamese letters through
    /// unencoded, which is not a valid URL.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func directURL(host: String, path: String) -> URL? {
        let encoded = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: unreserved) ?? String($0)
        }.joined(separator: "/")
        return URL(string: "smb://\(host)/\(encoded)")
    }

    /// A ready-to-play `VLCMedia` for "share/path/file.ext" on `host` over `route`, or nil if the URL could not be built.
    static func media(host: String, path: String, route: SmbPlaybackRoute, login: Login?) -> VLCMedia? {
        let media: VLCMedia
        switch route {
        case .direct:
            guard let url = directURL(host: host, path: path) else { return nil }
            media = VLCMedia(url: url)
            let domain = login?.domain ?? ""
            media.addOptions([
                "smb-user": login?.username ?? "",
                "smb-pwd": login?.password ?? "",
                "smb-domain": domain.isEmpty ? "WORKGROUP" : domain,
            ])
            PlaybackDiagnostics.append("smb: direct \(url.absoluteString) user=\(login?.username ?? "-")")
        case .proxy:
            guard let url = try? SmbHttpProxy.shared.url(host: host, path: path) else { return nil }
            media = VLCMedia(url: url)
            PlaybackDiagnostics.append("smb: proxy \(url.absoluteString)")
        }
        // A bit more buffer than VLC's 1s default: Wi-Fi to a home PC jitters.
        media.addOption(":network-caching=1500")
        return media
    }
}
