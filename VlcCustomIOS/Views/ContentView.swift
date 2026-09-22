import SwiftUI

struct ContentView: View {
    @ObservedObject private var musicQueue = MusicQueue.shared
    @State private var showMusicPlayer = false
    /// Lets CI's demo-screenshot workflow launch straight into a given tab (via the `DEMO_TAB` environment
    /// variable) so every screen can be screenshotted without a real device to tap through them by hand.
    @State private var selectedTab = Self.initialTab()

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
            }
            .navigationTitle("VLCcustom cho iOS")
        }
    }
}

#Preview {
    ContentView()
}
