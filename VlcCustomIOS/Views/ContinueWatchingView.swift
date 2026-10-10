import SwiftUI

/// Cài đặt → Đang xem dở: videos left part-way, the latest first. Tapping one carries on where it stopped; the rest
/// of its folder is queued too (from the saved listing), so the next episode follows.
struct ContinueWatchingView: View {
    @ObservedObject private var history = WatchHistory.shared
    @ObservedObject private var librarySettings = LibrarySettings.shared
    @State private var playing = false
    @State private var confirmClear = false

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "vi")
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        let items = Array(history.inProgress.prefix(100))
        List {
            if items.isEmpty {
                Text("Chưa có video nào xem dở. Video dừng giữa chừng (sau 30 giây đầu, trước phút cuối) sẽ hiện ở đây.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                Button { play(item) } label: { row(item) }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Xoá", role: .destructive) { history.clearPosition(item.source) }
                    }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Đang xem dở")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !items.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Xoá hết", role: .destructive) { confirmClear = true }
                }
            }
        }
        .confirmationDialog("Xoá toàn bộ danh sách đang xem dở?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Xoá hết \(items.count) video", role: .destructive) {
                withAnimation { history.clearAllPositions() }
            }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Mở lại các video này sẽ phát từ đầu. Dấu \"Đã xem\" của video đã xem hết vẫn giữ nguyên.")
        }
        .fullScreenCover(isPresented: $playing) {
            PlayerScreen(onClose: { withoutSlide { playing = false } })
        }
    }

    private func row(_ item: WatchHistory.InProgress) -> some View {
        HStack(spacing: 12) {
            VideoThumbnailView(source: item.source, size: librarySettings.thumbnailSize.rowHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.subheadline.weight(.medium)).lineLimit(2)
                Text(folderName(item.source)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text(detail(item)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.tint)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func folderName(_ source: String) -> String {
        guard let (host, path) = SmbUri.parse(source) else { return (source as NSString).deletingLastPathComponent }
        return "\(host)/\((path as NSString).deletingLastPathComponent)"
    }

    /// "Còn 12 phút · 2 giờ trước"
    private func detail(_ item: WatchHistory.InProgress) -> String {
        var parts: [String] = []
        if let duration = item.durationMs, duration > item.ms {
            let minutes = max(1, Int((duration - item.ms) / 60_000))
            parts.append("Còn \(minutes) phút")
        } else {
            parts.append("Dừng ở \(Self.clock(item.ms))")
        }
        parts.append(Self.relative.localizedString(for: item.at, relativeTo: Date()))
        return parts.joined(separator: " · ")
    }

    private static func clock(_ ms: Int32) -> String {
        let total = Int(ms) / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private func play(_ item: WatchHistory.InProgress) {
        let single = VideoItem(name: item.name, source: item.source, sizeBytes: 0, lastModified: .distantPast)
        guard let (host, path) = SmbUri.parse(item.source) else {
            PlaybackQueue.shared.start([single], index: 0, label: "Đang xem dở")
            withoutSlide { playing = true }
            return
        }
        Task {
            let folder = (path as NSString).deletingLastPathComponent
            let videos = (await SmbListingCache.get(host: host, path: folder) ?? []).filter { $0.kind == .video }
            if let entry = videos.first(where: { $0.path == path }) {
                // In the order the Mạng tab shows them, so "next" is the next episode.
                let sort = MediaSort(rawValue: UserDefaults.standard.string(forKey: "smb_sort") ?? "") ?? .nameAsc
                _ = SmbOpener.open(entry, siblings: sort.apply(videos), host: host, label: "SMB: \(host)/\(folder)")
            } else {
                PlaybackQueue.shared.start([single], index: 0, label: "Đang xem dở")
            }
            withoutSlide { playing = true }
        }
    }
}
