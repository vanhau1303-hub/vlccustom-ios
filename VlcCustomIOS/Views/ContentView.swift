import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    /// Lets CI's demo-screenshot workflow launch straight into a given tab (via the `DEMO_TAB` environment
    /// variable) so every screen can be screenshotted without a real device to tap through them by hand.
    @ObservedObject private var navigator = AppNavigator.shared
    @ObservedObject private var theme = AppTheme.shared
    @State private var demoPlaying = false

    var body: some View {
        TabView(selection: $navigator.selectedTab) {
            // Only the three screens used day to day stay in the tab bar; the Video/Nhạc/Ảnh/Playlist libraries
            // live inside Cài đặt → Thư viện.
            FavoritesView()
                .tabItem { Label("Yêu thích", systemImage: "star.fill") }.tag(0)
            SmbBrowserView()
                .tabItem { Label("Mạng", systemImage: "externaldrive.connected.to.line.below.fill") }.tag(1)
            SettingsView()
                .tabItem { Label("Cài đặt", systemImage: "gearshape.fill") }.tag(2)
        }
        // The main color and light / dark (Cài đặt → Giao diện).
        .tint(theme.accent)
        .preferredColorScheme(theme.colorScheme)
        .onAppear { theme.applyToWindows() }
        // Scrolling a list closes the keyboard too.
        .scrollDismissesKeyboard(.immediately)
        .onAppear { DispatchQueue.main.async { KeyboardDismisser.shared.install() } }
        .musicPlayerHost()
        .background(
            EmptyView().fullScreenCover(isPresented: $demoPlaying) {
                PlayerScreen(onClose: { demoPlaying = false })
            }
        )
        .task {
            // Background thumbnails for folders already visited, a little after start (SMB logins first).
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                ThumbnailBackfill.shared.startAll()
            }
            await startDemoSmbPlayback()
        }
    }

    /// CI end-to-end hook: with `DEMO_SMB_HOST` / `DEMO_SMB_USER` / `DEMO_SMB_PASS` / `DEMO_SMB_FILE` ("share/path")
    /// set, connects to that server and opens the file in the player straight away — lets the simulator workflow
    /// play a real video from a real (Samba) SMB server and collect the diagnostics log, with nobody tapping.
    private func startDemoSmbPlayback() async {
        let env = ProcessInfo.processInfo.environment
        // CI screenshots: open a folder in Mạng (DEMO_SMB_BROWSE = "share/path"), optionally starring it and a file.
        if let host = env["DEMO_SMB_HOST"], let folder = env["DEMO_SMB_BROWSE"] {
            await SmbRegistry.shared.registerUnchecked(host: host, username: env["DEMO_SMB_USER"] ?? "",
                                                       password: env["DEMO_SMB_PASS"] ?? "", domain: "")
            if env["DEMO_FAVORITES"] == "1", !FavoritesStore.isFavorite(host: host, path: folder) {
                FavoritesStore.toggle(host: host, path: folder, title: (folder as NSString).lastPathComponent)
                if let file = env["DEMO_SMB_FILE"] {
                    FavoritesStore.toggle(host: host, path: file, title: (file as NSString).lastPathComponent, isFile: true)
                }
            }
            if Self.demoTab() == 1 { navigator.openSmbFolder(host: host, path: folder) }
            return
        }
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
            let image = await ThumbnailService.vlcSnapshot(host: host, path: file, login: login, width: 640, position: 0.25,
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
        case .video: "film.fill"
        case .music: "music.note"
        case .images: "photo.fill.on.rectangle.fill"
        case .playlists: "list.bullet"
        }
    }
    var color: Color {
        switch self {
        case .video: .blue
        case .music: .pink
        case .images: .orange
        case .playlists: .purple
        }
    }
}

struct SettingsView: View {
    @State private var library: LibraryScreen?
    @ObservedObject private var backfill = ThumbnailBackfill.shared
    @ObservedObject private var history = WatchHistory.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ContinueWatchingView()
                    } label: {
                        HStack {
                            IconLabel("Đang xem dở", systemName: "clock.arrow.circlepath", color: .orange)
                            Spacer()
                            let count = history.inProgress.count
                            if count > 0 { Text("\(count)").foregroundStyle(.secondary) }
                        }
                    }
                }
                Section {
                    NavigationLink { AppearanceSettingsView() } label: {
                        IconLabel("Giao diện", systemName: "paintbrush.fill", color: AppTheme.shared.accent)
                    }
                    NavigationLink { PlayerSettingsView() } label: {
                        IconLabel("Trình phát", systemName: "play.rectangle.fill", color: .blue)
                    }
                    NavigationLink { SubtitleSettingsView() } label: {
                        IconLabel("Phụ đề", systemName: "captions.bubble.fill", color: .mint)
                    }
                    NavigationLink { ThumbnailSettingsView() } label: {
                        HStack {
                            IconLabel("Thumbnail", systemName: "photo.stack.fill", color: .indigo)
                            Spacer()
                            if backfill.phase != .idle {
                                Text("Đang chạy nền").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Thư viện") {
                    ForEach(LibraryScreen.allCases) { screen in
                        Button { library = screen } label: {
                            HStack {
                                IconLabel(screen.title, systemName: screen.icon, color: screen.color)
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        // Row text in the normal text color (a List button is drawn in the main color otherwise).
                        .buttonStyle(.plain)
                    }
                }
                Section {
                    NavigationLink { DiagnosticsSettingsView() } label: {
                        IconLabel("Chẩn đoán", systemName: "stethoscope", color: .green)
                    }
                    HStack {
                        IconLabel("Phiên bản", systemName: "info", color: .gray)
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Cài đặt")
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
                .tint(AppTheme.shared.accent)
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
