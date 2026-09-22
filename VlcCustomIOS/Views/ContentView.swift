import SwiftUI

struct ContentView: View {
    @ObservedObject private var musicQueue = MusicQueue.shared
    @State private var showMusicPlayer = false

    var body: some View {
        TabView {
            LocalLibraryView()
                .tabItem { Label("Video", systemImage: "internaldrive") }
            SmbBrowserView()
                .tabItem { Label("Mạng (SMB)", systemImage: "network") }
            MusicLibraryView()
                .tabItem { Label("Nhạc", systemImage: "music.note") }
            ImagesLibraryView()
                .tabItem { Label("Ảnh", systemImage: "photo.on.rectangle") }
            PlaylistsView()
                .tabItem { Label("Playlist", systemImage: "list.bullet") }
            FavoritesView()
                .tabItem { Label("Yêu thích", systemImage: "star") }
            SettingsView()
                .tabItem { Label("Cài đặt", systemImage: "gearshape") }
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
}

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Video (trên máy + SMB), Nhạc (phát nền, điều khiển ở màn hình khóa), Ảnh (xem có zoom, trình chiếu), " +
                         "Playlist, Yêu thích (thư mục SMB), thumbnail cho video/ảnh, tìm kiếm & sắp xếp, và trong trình phát: " +
                         "tốc độ phát, chọn track âm thanh/phụ đề, chỉnh màu, khử sọc, tỉ lệ khung hình.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Chưa có (dự kiến làm dần)") {
                    Text("Phụ đề AI (nhận dạng giọng nói), phụ đề song song + dịch tự động, khoá ứng dụng, sao chép/di chuyển/xoá file.")
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
