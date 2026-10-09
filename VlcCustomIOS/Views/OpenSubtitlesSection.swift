import SwiftUI

/// In "Âm thanh & Phụ đề": find subtitles for the video on OpenSubtitles (no key needed), pick one, and it is
/// added to the player as an ordinary subtitle track (VLC draws it, like a subtitle inside the file).
struct OpenSubtitlesSection: View {
    @ObservedObject var player: VlcPlayerController
    let onAdded: () -> Void
    @AppStorage("opensubtitles_langs") private var languages = "vi,en"

    @State private var results: [OpenSubtitles.Result]?
    @State private var searching = false
    @State private var downloading: String?
    @State private var message: String?
    @State private var failed = false

    private static let languageChoices: [(code: String, label: String)] = [
        ("vi,en", "Việt + Anh"), ("vi", "Tiếng Việt"), ("en", "Tiếng Anh"),
        ("vi,en,ja,ko,zh", "Việt, Anh, Nhật, Hàn, Trung"),
    ]

    var body: some View {
        Section {
            Picker("Ngôn ngữ", selection: $languages) {
                ForEach(Self.languageChoices, id: \.code) { Text($0.label).tag($0.code) }
            }
            Button { search() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass.circle.fill").font(.title3)
                    Text(results == nil ? "Tìm phụ đề trên OpenSubtitles" : "Tìm lại")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if searching { ProgressView() }
                }
            }
            .disabled(searching)
            if let results {
                if results.isEmpty {
                    Text("Không tìm thấy phụ đề cho video này (thử chọn thêm ngôn ngữ).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(results.prefix(30)) { result in
                    Button { use(result) } label: { row(result) }
                        .buttonStyle(.plain)
                        .disabled(downloading != nil)
                }
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(failed ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Tìm phụ đề trên mạng")
        } footer: {
            Text("Nguồn OpenSubtitles, không cần tài khoản. Dấu ✓ = khớp đúng file đang xem (đúng bản phim, đúng thời gian). Phụ đề tải về được lưu lại.")
        }
    }

    private func row(_ result: OpenSubtitles.Result) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(result.language.uppercased())
                .font(.caption2.weight(.bold)).foregroundStyle(.white)
                .frame(minWidth: 28).padding(.vertical, 3).padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(.tint))
            VStack(alignment: .leading, spacing: 3) {
                Text(result.release).font(.subheadline)
                    .lineLimit(2).truncationMode(.middle)
                HStack(spacing: 8) {
                    if result.hashMatch {
                        Label("Khớp file", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                    Label("\(result.downloads)", systemImage: "arrow.down.circle")
                    if result.hearingImpaired { Image(systemName: "ear") }
                    Text(result.format.uppercased())
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if downloading == result.fileId { ProgressView() }
        }
        .contentShape(Rectangle())
    }

    private func search() {
        guard let source = PlaybackQueue.shared.current?.source, let (host, path) = SmbUri.parse(source) else {
            failed = true
            message = "Chỉ hỗ trợ video trên SMB."
            return
        }
        searching = true
        message = nil
        failed = false
        let wanted = languages.split(separator: ",").map(String.init)
        Task {
            do {
                results = try await OpenSubtitles.search(host: host, path: path, languages: wanted)
            } catch {
                failed = true
                message = error.localizedDescription
            }
            searching = false
        }
    }

    private func use(_ result: OpenSubtitles.Result) {
        downloading = result.fileId
        message = nil
        failed = false
        Task {
            do {
                let file = try await OpenSubtitles.download(result)
                // The AI / translated overlay would sit on top of it.
                LiveSubtitles.shared.reset()
                player.addSubtitleFile(file)
                downloading = nil
                onAdded()
            } catch {
                failed = true
                message = error.localizedDescription
                downloading = nil
            }
        }
    }
}
