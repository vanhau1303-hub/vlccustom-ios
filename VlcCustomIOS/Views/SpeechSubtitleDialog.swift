import SwiftUI

/// Lets the user configure and start/stop AI subtitle generation for the video currently open in `PlayerScreen`.
struct SpeechSubtitleDialog: View {
    @ObservedObject var live: LiveSubtitles
    let videoName: String
    let durationMs: Int
    let source: String
    @ObservedObject private var settings = SpeechSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
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
