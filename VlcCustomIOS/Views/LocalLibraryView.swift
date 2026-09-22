import SwiftUI

/// "Trên máy" tab: pick a folder once (Files app), list the videos in it, play.
struct LocalLibraryView: View {
    @State private var folderURL: URL?
    @State private var videos: [VideoItem] = []
    @State private var loading = false
    @State private var showPicker = false
    @State private var playing: VideoItem?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Đang quét…")
                } else if videos.isEmpty {
                    ContentUnavailableFallback(
                        title: "Chưa có video",
                        message: "Chọn một thư mục trong ứng dụng Tệp để liệt kê video trong đó."
                    )
                } else {
                    List(videos) { video in
                        Button {
                            play(video)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(video.name).lineLimit(2)
                                Text(video.sizeLabel).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Video trên máy")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Chọn thư mục…") { showPicker = true }
                }
            }
            .sheet(isPresented: $showPicker) {
                FolderPicker { url in
                    LocalVideoService.saveBookmark(for: url)
                    load(url)
                }
            }
            .fullScreenCover(item: $playing) { _ in
                PlayerScreen(onClose: { playing = nil })
            }
            .task { restoreLastFolder() }
        }
    }

    private func restoreLastFolder() {
        guard videos.isEmpty, let url = LocalVideoService.restoredFolder() else { return }
        load(url)
    }

    private func load(_ url: URL) {
        folderURL = url
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = LocalVideoService.scan(url)
            DispatchQueue.main.async {
                videos = found
                loading = false
            }
        }
    }

    private func play(_ video: VideoItem) {
        PlaybackQueue.shared.start(videos, index: videos.firstIndex(of: video) ?? 0, label: folderURL?.lastPathComponent ?? "")
        playing = video
    }
}

/// A simple "nothing here yet" placeholder (kept dependency-free instead of iOS 17's ContentUnavailableView, so this
/// still compiles on iOS 16).
struct ContentUnavailableFallback: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "film").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
        }
    }
}
