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

/// Files that play (or give a thumbnail) through the proxy but not through libVLC's own SMB module — typically
/// fragmented / non-interleaved MP4s, which make libVLC seek thousands of times; its SMB module cancels the
/// in-flight read on every seek, the AMSMB2 proxy does not. Learned automatically (thumbnail fallback) or set by
/// hand ("Phát bằng chế độ tương thích"), remembered across launches.
enum SmbRoutePreferences {
    private static let key = "smb_proxy_route_sources"

    static func prefersProxy(_ source: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(source)
    }

    static func set(_ source: String, proxy: Bool) {
        var all = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        if proxy { all.insert(source) } else { all.remove(source) }
        UserDefaults.standard.set(Array(all), forKey: key)
    }
}

/// The per-media settings the official VLC for iOS app plays with (its app defaults, VLCAppDelegate /
/// VLCPlaybackService.mediaOptionsDictionary) — the setup that plays TS/MKV smoothly on the same devices:
/// - avcodec-skiploopfilter=1: skip the deblocking filter on non-reference frames — the big CPU saving when H.264 /
///   HEVC is decoded in software (common for MKV/TS), with no visible difference;
/// - network-caching=999ms (was 2000 here): faster start and seeks over the network;
/// - codec left automatic: VideoToolbox hardware decoding when the stream allows it, avcodec otherwise.
enum VLCTuning {
    static func apply(to media: VLCMedia, network: Bool = true) {
        media.addOption(":avcodec-skiploopfilter=1")
        if network { media.addOption(":network-caching=999") }
    }
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

    /// URL + libVLC options for "share/path" over `route` — what `media(...)` builds, as plain strings for the
    /// frame grabber (which drives libVLC directly). Proxy URLs made here are marked as background work.
    static func location(host: String, path: String, route: SmbPlaybackRoute, login: Login?) -> (url: String, options: [String])? {
        switch route {
        case .direct:
            guard let url = directURL(host: host, path: path) else { return nil }
            let domain = login?.domain ?? ""
            return (url.absoluteString, [
                ":smb-user=\(login?.username ?? "")",
                ":smb-pwd=\(login?.password ?? "")",
                ":smb-domain=\(domain.isEmpty ? "WORKGROUP" : domain)",
                ":network-caching=999",
            ])
        case .proxy:
            guard let url = try? SmbHttpProxy.shared.url(host: host, path: path, background: true) else { return nil }
            return (url.absoluteString, [":network-caching=999"])
        }
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
        VLCTuning.apply(to: media)
        return media
    }
}
