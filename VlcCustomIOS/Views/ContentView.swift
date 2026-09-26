import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    /// Lets CI's demo-screenshot workflow launch straight into a given tab (via the `DEMO_TAB` environment
    /// variable) so every screen can be screenshotted without a real device to tap through them by hand.
    @ObservedObject private var navigator = AppNavigator.shared
    @State private var demoPlaying = false

    var body: some View {
        TabView(selection: $navigator.selectedTab) {
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
        .task {
            if let tab = Self.demoTab() { navigator.selectedTab = tab }
            await startDemoSmbPlayback()
        }
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
        SmbRoutePreferences.set(item.source, proxy: env["DEMO_SMB_ROUTE"] == "proxy")
        // CI: grab a thumbnail frame first (VLCSnapshotter), over the requested route, and log the result.
        if env["DEMO_SMB_THUMB"] == "1" {
            let login = await SmbRegistry.shared.login(for: host)
            let started = Date()
            let image = await ThumbnailService.vlcSnapshot(host: host, path: file, login: login, width: 640, position: 0.1,
                                                           route: env["DEMO_SMB_ROUTE"] == "proxy" ? .proxy : .direct)
            let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
            PlaybackDiagnostics.append(image.map { "demo: thumb ok \($0.width)x\($0.height) in \(seconds)s" }
                                       ?? "demo: thumb FAILED after \(seconds)s")
        }
        // CI: find and read the existing subtitles (MKV track / file beside the video) and log what came out.
        if env["DEMO_SMB_SUBS"] == "1" {
            let options = await ExistingSubtitles.options(host: host, path: file)
            PlaybackDiagnostics.append("demo: subs options: " + options.map(\.label).joined(separator: " | "))
            for option in options {
                do {
                    let lines = try await ExistingSubtitles.load(option, host: host, videoPath: file) { _ in }
                    let first = lines.first.map { "\($0.startMs)-\($0.endMs) \($0.text)" } ?? "-"
                    PlaybackDiagnostics.append("demo: subs loaded \(lines.count) lines from \(option.id); first: \(first)")
                } catch {
                    PlaybackDiagnostics.append("demo: subs FAILED \(option.id): \(error.localizedDescription)")
                }
            }
        }
        PlaybackQueue.shared.start([item], index: 0, label: "demo")
        demoPlaying = true
    }

    private static func demoTab() -> Int? {
        ProcessInfo.processInfo.environment["DEMO_TAB"].flatMap(Int.init)
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
    @State private var thumbnailBytes: Int64 = 0
    @AppStorage(ThumbnailPolicy.fastKey) private var fastThumbnails = true

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
                Section {
                    Toggle(isOn: $fastThumbnails) {
                        Label("Ưu tiên tạo thumbnail nhanh", systemImage: "hare")
                    }
                    .onChange(of: fastThumbnails) { on in
                        ThumbnailPolicy.shared.fastEnabled = on
                        Task { await ThumbnailService.shared.policyChanged() }
                    }
                } footer: {
                    Text("Tạo 3 thumbnail cùng lúc và tạo trước cho cả thư mục. Khi mở video sẽ tự trở về chế độ bình thường (tạm dừng tạo thumbnail) để video không bị giật, đóng video thì chạy nhanh lại.")
                }
                Section {
                    HStack {
                        Label("Thumbnail đã lưu", systemImage: "photo.stack")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: thumbnailBytes, countStyle: .file)).foregroundStyle(.secondary)
                    }
                    Button("Xoá thumbnail", role: .destructive) {
                        Task {
                            await ThumbnailService.shared.clearAll()
                            thumbnailBytes = ThumbnailService.diskUsage()
                        }
                    }
                } footer: {
                    Text("Thumbnail được lưu trong bộ nhớ của ứng dụng, mở lại thư mục là hiện ngay, không phải tạo lại qua mạng.")
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
                    ShareLink(item: DiagnosticsLogFile(), preview: SharePreview("vlc_diagnostics.log")) {
                        Label("Chia sẻ log chẩn đoán", systemImage: "square.and.arrow.up")
                    }
                    Button("Xoá log", role: .destructive) { PlaybackDiagnostics.clear() }
                } footer: {
                    Text("Nếu video không phát được, hãy thử phát lại (để lỗi ghi vào log) rồi chia sẻ log này để chẩn đoán đúng nguyên nhân.")
                }
            }
            .navigationTitle("VLCcustom cho iOS")
            .task { thumbnailBytes = ThumbnailService.diskUsage() }
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

/// Shared as a fresh, complete snapshot taken at the moment of sharing (see `PlaybackDiagnostics.exportSnapshot`).
struct DiagnosticsLogFile: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { _ in
            SentTransferredFile(PlaybackDiagnostics.exportSnapshot())
        }
    }
}
