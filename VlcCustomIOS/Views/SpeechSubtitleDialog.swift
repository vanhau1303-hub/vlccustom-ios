import SwiftUI

/// Lets the user configure and start/stop AI subtitle generation for the video currently open in `PlayerScreen`.
struct SpeechSubtitleDialog: View {
    @ObservedObject var live: LiveSubtitles
    let videoName: String
    let durationMs: Int
    let source: String
    /// Hides libVLC's own rendering of the file's subtitles while the translated ones are shown.
    var onUseExisting: () -> Void = {}
    @ObservedObject private var settings = SpeechSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var options: [ExistingSubtitles.Option]?
    @State private var searching = false
    @State private var loadingOption: String?
    @State private var loadProgress: Double = 0
    @State private var existingError: String?
    @State private var apiKey = ClaudeTranslator.apiKey
    @State private var keyStatus: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(videoName)
                        .font(.footnote).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    if let options {
                        if options.isEmpty {
                            Label {
                                Text("Video này không có phụ đề dạng chữ bên trong, cũng không có file phụ đề kèm theo (.srt, .ass, .vtt cùng tên).")
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "captions.bubble").foregroundStyle(.secondary)
                            }
                            .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(options) { option in
                            Button { use(option) } label: { optionRow(option) }
                                .disabled(loadingOption != nil)
                        }
                    } else {
                        Button { findExisting() } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "text.magnifyingglass").frame(width: 24)
                                Text("Tìm phụ đề có sẵn")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if searching { ProgressView() }
                            }
                        }
                        .disabled(searching)
                    }
                    if let existingError {
                        Text(existingError).font(.footnote).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Dịch phụ đề có sẵn")
                } footer: {
                    Text("Tìm trong file MKV và file phụ đề cùng tên bên cạnh video, rồi dịch sang ngôn ngữ ở mục \"Dịch sang\".")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("Mô hình nhận dạng") {
                    Picker("Kích thước mô hình", selection: $settings.modelSize) {
                        ForEach(WhisperModelSize.allCases) { size in
                            Text(size == SpeechSettings.recommendedModel ? size.label + " · đề xuất cho máy này" : size.label).tag(size)
                        }
                    }
                    Text("Tải qua Internet ở lần dùng đầu tiên cho mỗi kích thước, các lần sau dùng lại không cần mạng.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Ngôn ngữ") {
                    Picker("Ngôn ngữ nói trong video", selection: $settings.spokenLanguage) {
                        Text("Tự động nhận diện").tag(String?.none)
                        ForEach(subtitleLanguages) { lang in Text(lang.name).tag(String?.some(lang.code)) }
                    }
                    Picker("Dịch sang", selection: $settings.translateTo) {
                        Text("Không dịch").tag(String?.none)
                        ForEach(subtitleLanguages) { lang in Text(lang.name).tag(String?.some(lang.code)) }
                    }
                    if settings.translateTo != nil {
                        Toggle("Hiện song ngữ (gốc + dịch)", isOn: $settings.dualSubtitles)
                    }
                }
                if settings.translateTo != nil {
                    Section {
                        Picker("Dịch bằng", selection: $settings.useClaude) {
                            Text("Google (miễn phí)").tag(false)
                            Text("Claude AI (API key riêng)").tag(true)
                        }
                        if settings.useClaude {
                            Picker("Mô hình", selection: $settings.claudeModel) {
                                ForEach(ClaudeTranslator.Model.allCases) { Text($0.label).tag($0) }
                            }
                            Picker("Phong cách", selection: $settings.translationStyle) {
                                ForEach(ClaudeTranslator.Style.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            SecureField("API key (sk-ant-…)", text: $apiKey)
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                                .onSubmit { ClaudeTranslator.apiKey = apiKey }
                            HStack {
                                Button("Lưu & kiểm tra key") {
                                    ClaudeTranslator.apiKey = apiKey
                                    keyStatus = "Đang kiểm tra…"
                                    Task { keyStatus = await ClaudeTranslator.check(model: settings.claudeModel) }
                                }
                                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                                Spacer()
                                if !ClaudeTranslator.apiKey.isEmpty {
                                    Button("Xoá key", role: .destructive) {
                                        ClaudeTranslator.apiKey = ""
                                        apiKey = ""
                                        keyStatus = nil
                                    }
                                }
                            }
                            .buttonStyle(.borderless)
                            if let keyStatus {
                                Text(keyStatus).font(.footnote).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            TextField("Máy chủ LibreTranslate (trống = Google)", text: $settings.libreTranslateServer)
                                .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                        }
                    } header: {
                        Text("Cách dịch")
                    } footer: {
                        if settings.useClaude {
                            Text("Tạo key ở console.anthropic.com (trả trước). Một tập phim ~22 phút tốn khoảng 0,3 USD với Opus 5.5, 0,15 USD với Sonnet 5.5, 0,07 USD với Haiku 4.5 (ước tính). Key lưu trong Keychain của máy. Đổi mô hình / phong cách thì phụ đề được dịch lại.")
                        }
                    }
                }
                if let status = live.status {
                    Section { HStack { ProgressView(); Text(status).font(.footnote) } }
                }
                if let note = live.translationNote {
                    Section { Label(note, systemImage: "globe").font(.footnote) }
                }
                if let error = live.errorMessage {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                Section {
                    if live.running {
                        Button("Dừng tạo phụ đề", role: .destructive) { live.stop() }
                    } else {
                        Button("Bắt đầu tạo phụ đề") { start() }
                    }
                } footer: {
                    Text("Phụ đề được tạo dần khi video đang phát và lưu lại — xem tiếp lần sau sẽ tiếp tục thay vì làm lại từ đầu.")
                }
                Section {
                    NavigationLink {
                        SubtitleStyleView()
                    } label: {
                        SubtitleStyleSummary()
                    }
                }
            }
            .navigationTitle("Phụ đề AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Đóng") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        // The choices last used for this folder (a series): language, translator, style, model.
        .onAppear { settings.applyFolderPreferences(for: source) }
        // Load an already-downloaded model while the user is still picking options.
        .task(id: settings.modelSize) {
            await WhisperEngine.shared.preloadIfDownloaded(model: settings.modelSize.rawValue)
        }
    }

    /// One found subtitle: where it is on the first line, details (language, format) below, progress on the right —
    /// long track / file names wrap instead of running into the spinner.
    private func optionRow(_ option: ExistingSubtitles.Option) -> some View {
        let parts = option.label.components(separatedBy: ": ")
        let place = parts.count > 1 ? parts[0] : nil
        let name = parts.count > 1 ? parts.dropFirst().joined(separator: ": ") : option.label
        return HStack(spacing: 12) {
            Image(systemName: place == "File kèm" ? "doc.text" : "captions.bubble").frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(2).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                if let place {
                    Text(place).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if loadingOption == option.id {
                if case .embedded = option.kind {
                    Text("\(Int(loadProgress * 100))%").font(.caption).monospacedDigit()
                }
                ProgressView()
            }
        }
    }

    private func findExisting() {
        guard let (host, path) = SmbUri.parse(source) else {
            existingError = "Chỉ hỗ trợ video trên SMB."
            return
        }
        searching = true
        existingError = nil
        Task {
            options = await ExistingSubtitles.options(host: host, path: path)
            searching = false
        }
    }

    private func use(_ option: ExistingSubtitles.Option) {
        guard let (host, path) = SmbUri.parse(source) else { return }
        loadingOption = option.id
        loadProgress = 0
        existingError = nil
        ExistingSubtitles.cancelled.reset()
        Task {
            do {
                let lines = try await ExistingSubtitles.load(option, host: host, videoPath: path) { fraction in
                    DispatchQueue.main.async { loadProgress = fraction }
                }
                settings.saveFolderPreferences(for: source)
                live.startFromExisting(source: source, optionID: option.id, lines: lines,
                                       translateTo: settings.translateTo,
                                       dual: settings.dualSubtitles && settings.translateTo != nil)
                onUseExisting()
                loadingOption = nil
                dismiss()
            } catch {
                existingError = error.localizedDescription
                loadingOption = nil
            }
        }
    }

    private func start() {
        settings.saveFolderPreferences(for: source)
        live.start(
            source: source,
            durationMs: durationMs,
            modelSize: settings.modelSize.rawValue,
            language: settings.spokenLanguage,
            translateTo: settings.translateTo,
            dual: settings.dualSubtitles && settings.translateTo != nil
        )
    }
}
