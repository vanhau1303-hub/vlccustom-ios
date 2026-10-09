import SwiftUI

/// In the subtitle sheet: find subtitles for this video on OpenSubtitles.com, pick one, it shows at once (and is
/// translated to "Dịch sang" when it is in another language).
struct OpenSubtitlesSection: View {
    let source: String
    @ObservedObject var live: LiveSubtitles
    let onApplied: () -> Void
    @ObservedObject private var settings = SpeechSettings.shared
    @AppStorage("opensubtitles_langs") private var languages = "vi,en"

    @State private var configured = OpenSubtitles.isConfigured
    @State private var showAccount = !OpenSubtitles.isConfigured
    @State private var apiKey = OpenSubtitles.apiKey
    @State private var username = OpenSubtitles.username
    @State private var password = OpenSubtitles.password
    @State private var accountStatus: String?

    @State private var results: [OpenSubtitles.Result]?
    @State private var searching = false
    @State private var downloading: Int?
    @State private var message: String?
    @State private var failed = false

    private static let languageChoices: [(code: String, label: String)] = [
        ("vi,en", "Việt + Anh"), ("vi", "Tiếng Việt"), ("en", "Tiếng Anh"),
        ("vi,en,ja,ko,zh-cn", "Việt, Anh, Nhật, Hàn, Trung"),
    ]

    var body: some View {
        Section {
            if configured {
                Picker("Ngôn ngữ", selection: $languages) {
                    ForEach(Self.languageChoices, id: \.code) { Text($0.label).tag($0.code) }
                }
                Button { search() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass.circle.fill").font(.title3)
                        Text(results == nil ? "Tìm trên OpenSubtitles" : "Tìm lại").frame(maxWidth: .infinity, alignment: .leading)
                        if searching { ProgressView() }
                    }
                }
                .disabled(searching)
                if let results {
                    if results.isEmpty {
                        Text("Không tìm thấy phụ đề cho video này (thử thêm ngôn ngữ khác).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(results.prefix(25)) { result in
                        Button { use(result) } label: { row(result) }
                            .disabled(downloading != nil)
                    }
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(failed ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            DisclosureGroup(isExpanded: $showAccount) {
                SecureField("API key", text: $apiKey)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                TextField("Tên đăng nhập (tuỳ chọn)", text: $username)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                SecureField("Mật khẩu (tuỳ chọn)", text: $password)
                Button("Lưu & kiểm tra") {
                    OpenSubtitles.apiKey = apiKey
                    OpenSubtitles.username = username
                    OpenSubtitles.password = password
                    configured = OpenSubtitles.isConfigured
                    accountStatus = "Đang kiểm tra…"
                    Task { accountStatus = await OpenSubtitles.check() }
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                if let accountStatus {
                    Text(accountStatus).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } label: {
                Label(configured ? "Tài khoản OpenSubtitles" : "Thiết lập OpenSubtitles", systemImage: "person.badge.key.fill")
            }
        } header: {
            Text("Tìm trên OpenSubtitles")
        } footer: {
            Text(configured
                 ? "Ưu tiên phụ đề khớp đúng file (dấu ✓). Phụ đề khác ngôn ngữ \"Dịch sang\" sẽ được dịch. Phụ đề đã tải được lưu lại, chọn lại không tốn lượt."
                 : "Tạo API key miễn phí ở opensubtitles.com → hồ sơ → API consumers. Đăng nhập tài khoản (tuỳ chọn) để được tải nhiều phụ đề hơn mỗi ngày.")
        }
    }

    private func row(_ result: OpenSubtitles.Result) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(result.language.uppercased())
                .font(.caption2.weight(.bold)).foregroundStyle(.white)
                .frame(minWidth: 30).padding(.vertical, 3).padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(.tint))
            VStack(alignment: .leading, spacing: 3) {
                Text(result.release).font(.subheadline).foregroundStyle(.primary)
                    .lineLimit(2).truncationMode(.middle)
                HStack(spacing: 8) {
                    if result.hashMatch {
                        Label("Khớp file", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                    Label("\(result.downloads)", systemImage: "arrow.down.circle")
                    if result.hearingImpaired { Image(systemName: "ear") }
                    if result.machineTranslated { Text("máy dịch") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if downloading == result.fileId { ProgressView() }
        }
    }

    private func search() {
        guard let (host, path) = SmbUri.parse(source) else {
            failed = true
            message = "Chỉ hỗ trợ video trên SMB."
            return
        }
        searching = true
        message = nil
        failed = false
        Task {
            do {
                results = try await OpenSubtitles.search(host: host, path: path, languages: languages)
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
                let (lines, note) = try await OpenSubtitles.download(result)
                // Already in the language to translate to: shown as is.
                let target = settings.translateTo
                let sameLanguage = target.map { result.language.lowercased().hasPrefix($0.lowercased()) } ?? true
                settings.saveFolderPreferences(for: source)
                live.startFromExisting(source: source, optionID: "os\(result.fileId)", lines: lines,
                                       translateTo: sameLanguage ? nil : target,
                                       dual: !sameLanguage && settings.dualSubtitles)
                message = note
                downloading = nil
                onApplied()
            } catch {
                failed = true
                message = error.localizedDescription
                downloading = nil
            }
        }
    }
}
