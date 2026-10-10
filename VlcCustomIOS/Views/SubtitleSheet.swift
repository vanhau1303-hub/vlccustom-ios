import SwiftUI

/// Everything about subtitles (and the audio track) in one sheet, opened from the player's captions button (and the
/// AI button, straight on its tab):
/// - Trong file: audio tracks, the file's own subtitle tracks, the look ("Kiểu chữ phụ đề");
/// - Tìm trên mạng: OpenSubtitles;
/// - AI: AI subtitles and translating subtitles that already exist.
/// The timing control on top moves whichever subtitles are showing.
struct SubtitleSheet: View {
    enum Tab: Hashable, Identifiable {
        case tracks, online, ai
        var id: Self { self }
    }

    @ObservedObject var player: VlcPlayerController
    @ObservedObject var live: LiveSubtitles
    @State var tab: Tab
    let videoName: String
    let source: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("", selection: $tab) {
                        Text("Trong file").tag(Tab.tracks)
                        Text("Tìm trên mạng").tag(Tab.online)
                        Text("AI").tag(Tab.ai)
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                SubtitleDelayRow(player: player, live: live)
                switch tab {
                case .tracks: tracks
                case .online: OpenSubtitlesSection(player: player) { dismiss() }
                case .ai:
                    SpeechSubtitleSections(live: live, videoName: videoName, durationMs: Int(player.duration), source: source,
                                           onUseExisting: { player.currentSubtitleTrack = -1 },
                                           onDone: { dismiss() })
                }
            }
            .navigationTitle("Phụ đề")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Xong") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .proPaywall(.subtitleSheet)
    }

    @ViewBuilder
    private var tracks: some View {
        Section("Phụ đề") {
            // VLCKit's list already has a "Disabled" entry.
            ForEach(player.subtitleTrackOptions) { option in
                Button {
                    player.currentSubtitleTrack = option.id
                    // A subtitle from OpenSubtitles is drawn by the app: picking another track (or "Tắt") replaces it.
                    if live.existingID?.hasPrefix(OpenSubtitles.optionPrefix) == true {
                        live.reset()
                    }
                    player.appDrawnSubtitleSource = nil
                } label: {
                    HStack {
                        Text(option.name).foregroundStyle(.primary)
                        Spacer()
                        if player.currentSubtitleTrack == option.id { Image(systemName: "checkmark") }
                    }
                }
            }
            NavigationLink {
                SubtitleStyleView()
            } label: {
                SubtitleStyleSummary()
            }
        }
        if player.audioTrackOptions.count > 1 {
            Section("Âm thanh") {
                ForEach(player.audioTrackOptions) { option in
                    Button {
                        player.currentAudioTrack = option.id
                    } label: {
                        HStack {
                            Text(option.name).foregroundStyle(.primary)
                            Spacer()
                            if player.currentAudioTrack == option.id { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
        }
    }
}

/// "Phụ đề sớm / trễ": ±0.5 s steps for whatever is showing — VLC's own subtitle track and the app's line (AI,
/// OpenSubtitles) alike. Back to 0 for each new video.
struct SubtitleDelayRow: View {
    @ObservedObject var player: VlcPlayerController
    @ObservedObject var live: LiveSubtitles

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Button { change(by: -500) } label: {
                    Image(systemName: "minus").frame(width: 36, height: 30)
                }
                VStack(spacing: 1) {
                    Text(label).font(.subheadline.weight(.semibold)).monospacedDigit()
                    Text(hint).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { set(0) }
                Button { change(by: 500) } label: {
                    Image(systemName: "plus").frame(width: 36, height: 30)
                }
            }
            .buttonStyle(.bordered)
        } header: {
            Text("Thời gian phụ đề")
        }
    }

    private var label: String {
        let ms = player.subtitleDelayMs
        if ms == 0 { return "Đúng giờ" }
        return String(format: "%@%.1f giây", ms > 0 ? "+" : "−", Double(abs(ms)) / 1000)
    }

    private var hint: String {
        switch player.subtitleDelayMs {
        case 0: return "− nếu chữ hiện trễ hơn tiếng, + nếu sớm hơn"
        case ..<0: return "Hiện sớm hơn · chạm để về 0"
        default: return "Hiện trễ hơn · chạm để về 0"
        }
    }

    private func change(by step: Int) { set(player.subtitleDelayMs + step) }

    private func set(_ ms: Int) {
        let value = min(30_000, max(-30_000, ms))
        player.subtitleDelayMs = value
        live.delayMs = value
    }
}
