import Foundation
import MobileVLCKit

/// "Kiểm tra file": asks libVLC (over its own SMB2 module, same route as playback) what is inside a file —
/// container length and every track's codec, resolution, frame rate, audio channels — so a file that will not play
/// can be told apart as "codec libVLC cannot decode", "broken/incomplete file" or "cannot be opened at all".
enum MediaInspector {
    struct Report {
        var lines: [String]
        var ok: Bool
    }

    @MainActor
    static func inspect(host: String, path: String) async -> Report {
        let login = await SmbRegistry.shared.login(for: host)
        guard let media = SmbPlayback.media(host: host, path: path, route: .direct, login: login) else {
            return Report(lines: ["Không tạo được đường dẫn tới file."], ok: false)
        }
        _ = media.parse(options: VLCMediaParsingOptions(rawValue: 0x01), timeout: 25_000) // parseNetwork
        let deadline = Date().addingTimeInterval(27)
        while media.parsedStatus.rawValue == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        var lines: [String] = []
        switch media.parsedStatus.rawValue {
        case 4: break // done
        case 3: lines.append("⚠️ Quá thời gian đọc thông tin (mạng chậm hoặc file cần đọc nhiều chỗ).")
        case 2: lines.append("❌ VLC không đọc được file này (hỏng, chưa tải xong, hoặc không phải định dạng video).")
        default: lines.append("⚠️ Chưa đọc xong thông tin file.")
        }

        let lengthMs = media.length.intValue
        if lengthMs > 0 { lines.append("Thời lượng: \(clock(Int(lengthMs)))") }

        let tracks = (media.tracksInformation as? [[String: Any]]) ?? []
        if tracks.isEmpty {
            lines.append("❌ Không tìm thấy luồng hình/tiếng nào.")
        }
        var hasVideo = false, hasAudio = false
        for track in tracks {
            let type = track[VLCMediaTracksInformationType] as? String ?? ""
            let fourcc = (track[VLCMediaTracksInformationCodec] as? NSNumber)?.uint32Value ?? 0
            let codec = VLCMedia.codecName(forFourCC: fourcc, trackType: type)
            switch type {
            case VLCMediaTracksInformationTypeVideo:
                hasVideo = true
                let w = (track[VLCMediaTracksInformationVideoWidth] as? NSNumber)?.intValue ?? 0
                let h = (track[VLCMediaTracksInformationVideoHeight] as? NSNumber)?.intValue ?? 0
                let rate = (track[VLCMediaTracksInformationFrameRate] as? NSNumber)?.doubleValue ?? 0
                let den = (track[VLCMediaTracksInformationFrameRateDenominator] as? NSNumber)?.doubleValue ?? 0
                let fps = den > 0 ? String(format: ", %.2f fps", rate / den) : ""
                let profile = (track[VLCMediaTracksInformationCodecProfile] as? NSNumber)?.intValue ?? 0
                lines.append("🎬 Hình: \(codec) \(w > 0 ? "\(w)×\(h)" : "")\(fps)\(profile > 0 ? ", profile \(profile)" : "")")
            case VLCMediaTracksInformationTypeAudio:
                hasAudio = true
                let ch = (track[VLCMediaTracksInformationAudioChannelsNumber] as? NSNumber)?.intValue ?? 0
                let hz = (track[VLCMediaTracksInformationAudioRate] as? NSNumber)?.intValue ?? 0
                let lang = track[VLCMediaTracksInformationLanguage] as? String ?? ""
                lines.append("🔊 Tiếng: \(codec)\(ch > 0 ? ", \(ch) kênh" : "")\(hz > 0 ? ", \(hz) Hz" : "")\(lang.isEmpty ? "" : ", \(lang)")")
            case VLCMediaTracksInformationTypeText:
                let lang = track[VLCMediaTracksInformationLanguage] as? String ?? ""
                lines.append("💬 Phụ đề: \(codec)\(lang.isEmpty ? "" : ", \(lang)")")
            default:
                lines.append("• Luồng khác: \(codec)")
            }
        }
        if !tracks.isEmpty && !hasVideo && hasAudio { lines.append("ℹ️ File chỉ có tiếng, không có hình.") }
        PlaybackDiagnostics.append("inspect: \(path) → " + lines.joined(separator: " | "))
        return Report(lines: lines, ok: media.parsedStatus.rawValue == 4 && hasVideo || hasAudio)
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }
}
