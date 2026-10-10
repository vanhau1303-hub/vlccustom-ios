import MediaPlayer
import SwiftUI

/// Cài đặt → Trình phát.
enum PlayerSettings {
    static let autoResumeKey = "player_auto_resume"
    static let doubleTapKey = "player_double_tap_seconds"
    static let remainingKey = "player_show_remaining"
    static let backgroundAudioKey = "player_background_audio"
    static let cachingKey = "player_network_caching"
    static let doubleTapChoices = [10, 15, 30]

    /// How much video libVLC reads ahead before showing a picture (after opening and after every seek). 667 ms —
    /// VLC's own "low latency" preset — is a third quicker than the 999 ms used before and still covers Wi-Fi
    /// hiccups at home; a video that stalls twice moves the next ones a step up (`raiseCaching`).
    static let cachingChoices: [(ms: Int, label: String)] = [
        (333, "Thấp · 0,3 giây"),
        (667, "Vừa · 0,7 giây (đề xuất)"),
        (999, "Cao · 1 giây (như trước)"),
        (1667, "Rất cao · 1,7 giây (Wi-Fi yếu)"),
    ]
    static let defaultCachingMs = 667

    /// Open a video where it was left off (a "Xem từ đầu" button shows for a few seconds) instead of offering to.
    static var autoResume: Bool { UserDefaults.standard.object(forKey: autoResumeKey) as? Bool ?? true }

    /// How far a double tap on the left / right third jumps.
    static var doubleTapSeconds: Int {
        let value = UserDefaults.standard.integer(forKey: doubleTapKey)
        return doubleTapChoices.contains(value) ? value : 30
    }

    /// Keep the sound going (picture off) when the screen locks or the app goes to the background.
    static var backgroundAudio: Bool { UserDefaults.standard.bool(forKey: backgroundAudioKey) }

    static var networkCachingMs: Int {
        let value = UserDefaults.standard.integer(forKey: cachingKey)
        return cachingChoices.contains { $0.ms == value } ? value : defaultCachingMs
    }

    /// One step up (a video stalled twice); nil when already at the top.
    static func raiseCaching() -> Int? {
        guard let index = cachingChoices.firstIndex(where: { $0.ms == networkCachingMs }),
              index + 1 < cachingChoices.count else { return nil }
        let next = cachingChoices[index + 1].ms
        UserDefaults.standard.set(next, forKey: cachingKey)
        return next
    }
}

struct PlayerSettingsView: View {
    @AppStorage(PlayerSettings.autoResumeKey) private var autoResume = true
    @AppStorage(PlayerSettings.doubleTapKey) private var doubleTap = 30
    @AppStorage(PlayerSettings.remainingKey) private var showRemaining = false
    @AppStorage(PlayerSettings.backgroundAudioKey) private var backgroundAudio = false
    @AppStorage(PlayerSettings.cachingKey) private var caching = PlayerSettings.defaultCachingMs

    var body: some View {
        List {
            Section {
                Toggle(isOn: $autoResume) {
                    IconLabel("Tự xem tiếp", systemName: "play.circle.fill", color: .blue)
                }
            } footer: {
                Text("Mở lại video đang xem dở là phát luôn từ chỗ đã dừng (lùi 2 giây), có nút \"Xem từ đầu\" hiện vài giây. Tắt thì hỏi trước như cũ.")
            }
            Section {
                Picker(selection: $doubleTap) {
                    ForEach(PlayerSettings.doubleTapChoices, id: \.self) { Text("\($0) giây").tag($0) }
                } label: {
                    IconLabel("Chạm 2 lần để tua", systemName: "hand.tap.fill", color: .orange)
                }
                Toggle(isOn: $showRemaining) {
                    IconLabel("Hiện thời gian còn lại", systemName: "timer", color: .teal)
                }
            } footer: {
                Text("Chạm 2 lần vào bên trái / phải màn hình để tua lùi / tới. Chạm vào thời lượng ở cuối thanh tua cũng đổi qua lại giữa tổng thời lượng và thời gian còn lại.")
            }
            Section {
                Picker(selection: $caching) {
                    ForEach(PlayerSettings.cachingChoices, id: \.ms) { Text($0.label).tag($0.ms) }
                } label: {
                    IconLabel("Bộ đệm mạng", systemName: "speedometer", color: .green)
                }
            } footer: {
                Text("Lượng video đọc trước khi hiện hình (lúc mở và sau mỗi lần tua). Thấp hơn: mở và tua nhanh hơn; cao hơn: chịu được Wi-Fi chập chờn. Video nào bị đứng hình chờ tải 2 lần thì app tự nâng lên một mức cho các lần mở sau. Áp dụng từ video mở tiếp theo.")
            }
            Section {
                Toggle(isOn: $backgroundAudio) {
                    IconLabel("Nghe tiếp khi khoá màn hình", systemName: "lock.iphone", color: .indigo)
                }
            } footer: {
                Text("Khoá máy hoặc thoát ra ngoài khi đang xem: tiếng vẫn phát tiếp (tắt hình cho đỡ tốn pin), điều khiển được ở màn hình khoá. Mở lại app là có hình ngay. Tắt thì video dừng và mở lại đúng chỗ khi quay lại.")
            }
        }
        .navigationTitle("Trình phát")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// What the lock screen / Control Center buttons control.
protocol RemoteControllable: AnyObject {
    func remotePlay()
    func remotePause()
    func remoteTogglePlayPause()
    func remoteNext()
    func remotePrevious()
    func remoteSeek(toSeconds seconds: Double)
}

/// The lock screen / Control Center buttons, registered once: they control the video playing in the background when
/// there is one, the music player otherwise.
final class RemoteCommands {
    static let shared = RemoteCommands()
    weak var music: RemoteControllable?
    weak var video: RemoteControllable?
    private var target: RemoteControllable? { video ?? music }

    private init() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.run { $0.remotePlay() } ?? .commandFailed }
        center.pauseCommand.addTarget { [weak self] _ in self?.run { $0.remotePause() } ?? .commandFailed }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.run { $0.remoteTogglePlayPause() } ?? .commandFailed }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.run { $0.remoteNext() } ?? .commandFailed }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.run { $0.remotePrevious() } ?? .commandFailed }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.run { $0.remoteSeek(toSeconds: event.positionTime) } ?? .commandFailed
        }
    }

    /// Makes sure the targets above exist (the first use creates them).
    func activate() {}

    private func run(_ action: (RemoteControllable) -> Void) -> MPRemoteCommandHandlerStatus {
        guard let target else { return .noActionableNowPlayingItem }
        action(target)
        return .success
    }
}
