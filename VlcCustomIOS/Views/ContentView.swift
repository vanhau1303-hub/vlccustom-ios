import SwiftUI

struct ContentView: View {
    @ObservedObject private var musicQueue = MusicQueue.shared
    @State private var showMusicPlayer = false
    /// Lets CI's demo-screenshot workflow launch straight into a given tab (via the `DEMO_TAB` environment
    /// variable) so every screen can be screenshotted without a real device to tap through them by hand.
    @State private var selectedTab = Self.initialTab()
    @State private var demoPlaying = false

    var body: some View {
        TabView(selection: $selectedTab) {
            LocalLibraryView()
                .tabItem { Label("Video", systemImage: "internaldrive") }.tag(0)
            SmbBrowserView()
                .tabItem { Label("Mạng (SMB)", systemImage: "network") }.tag(1)
            MusicLibraryView()
                .tabItem { Label("Nhạc", systemImage: "music.note") }.tag(2)
            ImagesLibraryView()
                .tabItem { Label("Ảnh", systemImage: "photo.on.rectangle") }.tag(3)
            PlaylistsView()
                .tabItem { Label("Playlist", systemImage: "list.bullet") }.tag(4)
            FavoritesView()
                .tabItem { Label("Yêu thích", systemImage: "star") }.tag(5)
            SettingsView()
                .tabItem { Label("Cài đặt", systemImage: "gearshape") }.tag(6)
        }
        .safeAreaInset(edge: .bottom) {
            if musicQueue.current != nil {
                NowPlayingBar(onTap: { showMusicPlayer = true })
            }
        }
        .fullScreenCover(isPresented: $showMusicPlayer) {
            MusicPlayerScreen(onClose: { showMusicPlayer = false })
        }
        .background(
            EmptyView().fullScreenCover(isPresented: $demoPlaying) {
                PlayerScreen(onClose: { demoPlaying = false })
            }
        )
        .task { await startDemoSmbPlayback() }
    }

    /// CI end-to-end hook: with `DEMO_SMB_HOST` / `DEMO_SMB_USER` / `DEMO_SMB_PASS` / `DEMO_SMB_FILE` ("share/path")
    /// set, connects to that server and opens the file in the player straight away — lets the simulator workflow
    /// play a real video from a real (Samba) SMB server and collect the diagnostics log, with nobody tapping.
    private func startDemoSmbPlayback() async {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DEMO_SMB_HOST"], let file = env["DEMO_SMB_FILE"] else { return }
        await SmbRegistry.shared.registerUnchecked(host: host, username: env["DEMO_SMB_USER"] ?? "",
                                                   password: env["DEMO_SMB_PASS"] ?? "", domain: "")
        let item = VideoItem(name: (file as NSString).lastPathComponent, source: "smb://\(host)/\(file)",
                             sizeBytes: 0, lastModified: .distantPast)
        PlaybackQueue.shared.start([item], index: 0, label: "demo")
        demoPlaying = true
    }

    private static func initialTab() -> Int {
        guard let raw = ProcessInfo.processInfo.environment["DEMO_TAB"], let value = Int(raw) else { return 0 }
        return value
    }
}

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Video (trên máy + SMB), Nhạc (phát nền, điều khiển ở màn hình khóa), Ảnh (xem có zoom, trình chiếu), " +
                         "Playlist, Yêu thích (thư mục SMB), thumbnail cho video/ảnh, tìm kiếm & sắp xếp, và trong trình phát: " +
                         "tốc độ phát, chọn track âm thanh/phụ đề, chỉnh màu, khử sọc, tỉ lệ khung hình, phụ đề AI (nhận dạng " +
                         "giọng nói ngay trên máy) và dịch tự động sang ngôn ngữ khác.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Chưa có (dự kiến làm dần)") {
                    Text("Khoá ứng dụng.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Text("Phiên bản")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    ShareLink(item: PlaybackDiagnostics.logURL) {
                        Label("Chia sẻ log chẩn đoán", systemImage: "square.and.arrow.up")
                    }
                    Button("Xoá log", role: .destructive) { PlaybackDiagnostics.clear() }
                } footer: {
                    Text("Nếu video không phát được, hãy thử phát lại (để lỗi ghi vào log) rồi chia sẻ log này để chẩn đoán đúng nguyên nhân.")
                }
            }
            .navigationTitle("VLCcustom cho iOS")
        }
    }
}

#Preview {
    ContentView()
}
