import MediaPlayer
import SwiftUI

/// Cài đặt → Trình phát.
enum PlayerSettings {
    static let autoResumeKey = "player_auto_resume"
    static let doubleTapKey = "player_double_tap_seconds"
    static let remainingKey = "player_show_remaining"
    static let backgroundAudioKey = "player_background_audio"
    static let doubleTapChoices = [10, 15, 30]

    /// Open a video where it was left off (a "Xem từ đầu" button shows for a few seconds) instead of offering to.
    static var autoResume: Bool { UserDefaults.standard.object(forKey: autoResumeKey) as? Bool ?? true }

    /// How far a double tap on the left / right third jumps.
    static var doubleTapSeconds: Int {
        let value = UserDefaults.standard.integer(forKey: doubleTapKey)
        return doubleTapChoices.contains(value) ? value : 30
    }

    /// Keep the sound going (picture off) when the screen locks or the app goes to the background.
    static var backgroundAudio: Bool { UserDefaults.standard.bool(forKey: backgroundAudioKey) }
}

struct PlayerSettingsView: View {
    @AppStorage(PlayerSettings.autoResumeKey) private var autoResume = true
    @AppStorage(PlayerSettings.doubleTapKey) private var doubleTap = 30
    @AppStorage(PlayerSettings.remainingKey) private var showRemaining = false
    @AppStorage(PlayerSettings.backgroundAudioKey) private var backgroundAudio = false

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
