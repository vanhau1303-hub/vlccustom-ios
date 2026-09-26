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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let options {
                        if options.isEmpty {
                            Text("Không tìm thấy phụ đề dạng chữ trong file hoặc file phụ đề kèm theo.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(options) { option in
                            Button { use(option) } label: {
                                HStack {
                                    Label(option.label, systemImage: "captions.bubble")
                                    Spacer()
                                    if loadingOption == option.id {
                                        if case .embedded = option.kind {
                                            Text("\(Int(loadProgress * 100))%").font(.caption).monospacedDigit()
                                        }
                                        ProgressView()
                                    }
                                }
                            }
                            .disabled(loadingOption != nil)
                        }
                    } else {
                        Button { findExisting() } label: {
                            HStack {
                                Label("Tìm phụ đề có sẵn (trong file / file kèm)", systemImage: "text.magnifyingglass")
                                if searching { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(searching)
                    }
                    if let existingError {
                        Text(existingError).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Dịch phụ đề có sẵn")
                } footer: {
                    Text("Dịch sang ngôn ngữ chọn ở mục \"Dịch sang\" bên dưới (không chọn thì chỉ hiện phụ đề gốc). Phụ đề nằm trong file MKV cần đọc hết file một lần qua mạng.")
                }
                Section("Mô hình nhận dạng") {
                    Picker("Kích thước mô hình", selection: $settings.modelSize) {
                        ForEach(WhisperModelSize.allCases) { size in Text(size.label).tag(size) }
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
                        TextField("Máy chủ LibreTranslate riêng (để trống = Google, miễn phí)", text: $settings.libreTranslateServer)
                            .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .keyboardType(.URL)
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
            }
            .navigationTitle("Phụ đề AI: \(videoName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Đóng") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
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
