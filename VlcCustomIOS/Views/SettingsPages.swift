import SwiftUI

/// Cài đặt → Giao diện.
struct AppearanceSettingsView: View {
    var body: some View {
        List { ThemeSettingsSection() }
            .navigationTitle("Giao diện")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Cài đặt → Phụ đề: the look of subtitles and what happens to subtitles found on OpenSubtitles.
struct SubtitleSettingsView: View {
    @AppStorage("opensubtitles_translate") private var translateDownloaded = true

    var body: some View {
        List {
            SubtitleStyleSection()
            Section {
                Toggle(isOn: $translateDownloaded) {
                    IconLabel("Dịch phụ đề tải về sang tiếng Việt", systemName: "globe", color: .blue)
                }
            } footer: {
                Text("Phụ đề tìm trên OpenSubtitles mà không phải tiếng Việt được dịch từng câu ngay khi xem, bằng cách dịch đã chọn cho phụ đề AI (Google hoặc Claude).")
            }
        }
        .navigationTitle("Phụ đề")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Cài đặt → Thumbnail.
struct ThumbnailSettingsView: View {
    @State private var thumbnailBytes: Int64 = 0
    @AppStorage(ThumbnailPolicy.fastKey) private var fastThumbnails = true
    @AppStorage(ThumbnailPolicy.animatedKey) private var animatedThumbnails = false
    @AppStorage(ThumbnailBackfill.enabledKey) private var backfillThumbnails = true
    @ObservedObject private var backfill = ThumbnailBackfill.shared

    var body: some View {
        List {
            Section {
                Toggle(isOn: $fastThumbnails) {
                    IconLabel("Ưu tiên tạo thumbnail nhanh", systemName: "hare.fill", color: .orange)
                }
                .onChange(of: fastThumbnails) { on in
                    ThumbnailPolicy.shared.fastEnabled = on
                    Task { await ThumbnailService.shared.policyChanged() }
                }
            } footer: {
                Text("Tạo nhiều thumbnail cùng lúc và tạo trước cho cả thư mục. Khi mở video sẽ tự trở về chế độ bình thường (tạm dừng tạo thumbnail) để video không bị giật, đóng video thì chạy nhanh lại.")
            }
            Section {
                Toggle(isOn: $backfillThumbnails) {
                    IconLabel("Tạo thumbnail nền", systemName: "square.stack.3d.down.right.fill", color: .indigo)
                }
                .onChange(of: backfillThumbnails) { on in backfill.setEnabled(on) }
                if backfillThumbnails {
                    ThumbnailBackfillStatusRow()
                }
                NavigationLink {
                    ThumbnailBackfillFoldersView()
                } label: {
                    HStack {
                        IconLabel("Thư mục đã xem", systemName: "folder.fill", color: .blue)
                        Spacer()
                        Text("\(backfill.visitedCount)").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Thumbnail nền")
            } footer: {
                Text("Tự tạo thumbnail (thường + động) còn thiếu cho các thư mục SMB đã mở, từng cái một. Thư mục đang xem luôn được làm trước, sau đó theo thứ tự đã sắp xếp trong \"Thư mục đã xem\". Khi đang xem video sẽ tự chờ.")
            }
            Section {
                Toggle(isOn: $animatedThumbnails) {
                    IconLabel("Thumbnail động", systemName: "play.rectangle.on.rectangle.fill", color: .pink)
                }
            } footer: {
                Text("Video trong thư mục SMB lần lượt hiện 6 cảnh (10% → 85% thời lượng). Các cảnh được Thumbnail nền tạo sẵn (kể cả khi tắt mục này), nên bật lên là có ngay; khoảng 150KB mỗi video.")
            }
            Section {
                HStack {
                    IconLabel("Thumbnail đã lưu", systemName: "photo.stack.fill", color: .teal)
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
        }
        .navigationTitle("Thumbnail")
        .navigationBarTitleDisplayMode(.inline)
        .task { thumbnailBytes = ThumbnailService.diskUsage() }
    }
}

/// Cài đặt → Chẩn đoán.
struct DiagnosticsSettingsView: View {
    @State private var verbose = UserDefaults.standard.bool(forKey: PlaybackDiagnostics.verboseKey)

    var body: some View {
        List {
            Section {
                ShareLink(item: DiagnosticsLogFile(), preview: SharePreview("vlc_diagnostics.log")) {
                    IconLabel("Chia sẻ log chẩn đoán", systemName: "square.and.arrow.up", color: .green)
                }
                Button("Xoá log", role: .destructive) { PlaybackDiagnostics.clear() }
            } footer: {
                Text("Nếu video không phát được, hãy thử phát lại (để lỗi ghi vào log) rồi chia sẻ log này để chẩn đoán đúng nguyên nhân.")
            }
            Section {
                Toggle(isOn: $verbose) {
                    IconLabel("Log chi tiết", systemName: "doc.text.magnifyingglass", color: .gray)
                }
                .onChange(of: verbose) { PlaybackDiagnostics.setVerbose($0) }
            } footer: {
                Text("Ghi cả thông tin chi tiết của VLC (không chỉ lỗi và cảnh báo). Bật khi cần gửi log để tìm lỗi, xong thì tắt cho đỡ tốn pin.")
            }
        }
        .navigationTitle("Chẩn đoán")
        .navigationBarTitleDisplayMode(.inline)
    }
}
