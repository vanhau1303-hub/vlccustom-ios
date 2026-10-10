import SwiftUI

/// In "Âm thanh & Phụ đề": find subtitles for the video on OpenSubtitles (no key needed), pick one, and it is shown
/// by the app like the AI subtitles (same look, "Kiểu chữ phụ đề"), with VLC's own subtitle track turned off.
struct OpenSubtitlesSection: View {
    @ObservedObject var player: VlcPlayerController
    let onAdded: () -> Void
    @ObservedObject private var live = LiveSubtitles.shared
    @ObservedObject private var account = OpenSubtitlesAccount.shared
    @AppStorage("opensubtitles_langs") private var languages = "vi,en"
    /// A subtitle in another language is translated into Vietnamese by the translator chosen for AI subtitles.
    @AppStorage("opensubtitles_translate") private var translate = true

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
            Toggle("Dịch sang tiếng Việt nếu là ngôn ngữ khác", isOn: $translate)
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
            Text(footerText)
        }
    }

    private var footerText: String {
        var text: String
        if account.isLoggedIn {
            text = "Tải bằng tài khoản OpenSubtitles \(account.username)"
            if let remaining = account.remaining { text += " (còn \(remaining) lượt hôm nay)" }
            text += ". "
        } else {
            text = "Chưa đăng nhập OpenSubtitles: ít lượt tải mỗi ngày — đăng nhập tài khoản miễn phí ở Cài đặt → Phụ đề. "
        }
        return text + "\"Khớp file\" = đúng bản phim đang xem (đúng thời gian). Phụ đề tải về được lưu lại và hiện giống phụ đề AI."
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
            if downloading == result.fileId {
                ProgressView()
            } else if live.existingID == OpenSubtitles.optionPrefix + result.fileId {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }

    private func search() {
        guard ProStore.shared.require("Tìm phụ đề trên mạng", in: .subtitleSheet) else { return }
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
                let lines = OpenSubtitles.lines(of: file)
                if let source = PlaybackQueue.shared.current?.source, !lines.isEmpty {
                    // Drawn by the app like the AI subtitles; VLC's own subtitle would show underneath.
                    player.currentSubtitleTrack = -1
                    player.appDrawnSubtitleSource = source
                    // Not Vietnamese: translated line by line in place (same queue as the AI subtitles).
                    let target = translate && result.language != "vi" ? "vi" : nil
                    LiveSubtitles.shared.startFromExisting(source: source, optionID: OpenSubtitles.optionPrefix + result.fileId,
                                                           lines: lines, translateTo: target,
                                                           dual: target != nil && SpeechSettings.shared.dualSubtitles,
                                                           sourceLanguage: result.language)
                } else {
                    // A format the app does not read: VLC shows it as a subtitle track.
                    LiveSubtitles.shared.reset()
                    player.appDrawnSubtitleSource = nil
                    player.addSubtitleFile(file)
                }
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
