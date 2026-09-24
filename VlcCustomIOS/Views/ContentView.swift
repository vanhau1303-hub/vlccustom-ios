import SwiftUI

struct ContentView: View {
    /// Lets CI's demo-screenshot workflow launch straight into a given tab (via the `DEMO_TAB` environment
    /// variable) so every screen can be screenshotted without a real device to tap through them by hand.
    @State private var selectedTab = Self.initialTab()
    @State private var demoPlaying = false

    var body: some View {
        TabView(selection: $selectedTab) {
            // Only the three screens used day to day stay in the tab bar; the Video/Nhạc/Ảnh/Playlist libraries
            // live inside Cài đặt → Thư viện.
            FavoritesView()
                .tabItem { Label("Yêu thích", systemImage: "star") }.tag(0)
            SmbBrowserView()
                .tabItem { Label("Mạng", systemImage: "network") }.tag(1)
            SettingsView()
                .tabItem { Label("Cài đặt", systemImage: "gearshape") }.tag(2)
        }
        .musicPlayerHost()
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
        guard let raw = ProcessInfo.processInfo.environment["DEMO_TAB"], let value = Int(raw) else { return 1 }
        return value
    }
}

/// The libraries that used to be their own tabs, opened from Cài đặt → Thư viện.
private enum LibraryScreen: String, Identifiable, CaseIterable {
    case video, music, images, playlists
    var id: String { rawValue }
    var title: String {
        switch self {
        case .video: "Video trên máy"
        case .music: "Nhạc"
        case .images: "Ảnh"
        case .playlists: "Playlist"
        }
    }
    var icon: String {
        switch self {
        case .video: "film"
        case .music: "music.note"
        case .images: "photo.on.rectangle"
        case .playlists: "list.bullet"
        }
    }
}

struct SettingsView: View {
    @State private var library: LibraryScreen?

    var body: some View {
        NavigationStack {
            List {
                Section("Thư viện") {
                    ForEach(LibraryScreen.allCases) { screen in
                        Button { library = screen } label: {
                            Label(screen.title, systemImage: screen.icon)
                        }
                    }
                }
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
            .sheet(item: $library) { screen in
                Group {
                    switch screen {
                    case .video: LocalLibraryView()
                    case .music: MusicLibraryView()
                    case .images: ImagesLibraryView()
                    case .playlists: PlaylistsView()
                    }
                }
                .musicPlayerHost()
            }
        }
    }
}

#Preview {
    ContentView()
}
