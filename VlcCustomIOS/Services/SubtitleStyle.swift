import Combine
import SwiftUI
import UIKit

/// How subtitles look: size, color, font, bold and background. The app's own subtitle line (AI subtitles, subtitles
/// downloaded from OpenSubtitles) uses all of it; VLC, for the subtitles it draws itself (tracks inside the file,
/// files beside it), gets size, color, font and bold — it has no background setting while playing.
final class SubtitleStyle: ObservableObject {
    static let shared = SubtitleStyle()

    enum FontChoice: String, CaseIterable, Identifiable {
        case system, rounded, helvetica, arial, georgia, times
        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "SF (mặc định)"
            case .rounded: return "SF bo tròn"
            case .helvetica: return "Helvetica Neue"
            case .arial: return "Arial"
            case .georgia: return "Georgia"
            case .times: return "Times New Roman"
            }
        }

        func font(size: CGFloat, bold: Bool) -> Font {
            let weight: Font.Weight = bold ? .bold : .medium
            switch self {
            case .system: return .system(size: size, weight: weight)
            case .rounded: return .system(size: size, weight: weight, design: .rounded)
            case .helvetica: return .custom("HelveticaNeue", size: size).weight(weight)
            case .arial: return .custom("ArialMT", size: size).weight(weight)
            case .georgia: return .custom("Georgia", size: size).weight(weight)
            case .times: return .custom("TimesNewRomanPSMT", size: size).weight(weight)
            }
        }

        /// The family VLC's text renderer looks up; the SF fonts cannot be reached by name there.
        var vlcFamily: String {
            switch self {
            case .system, .rounded, .helvetica: return "Helvetica Neue"
            case .arial: return "Arial"
            case .georgia: return "Georgia"
            case .times: return "Times New Roman"
            }
        }
    }

    struct Swatch: Identifiable {
        let name: String
        let hex: String
        var id: String { hex }
    }

    static let swatches: [Swatch] = [
        Swatch(name: "Trắng", hex: "#FFFFFF"),
        Swatch(name: "Vàng", hex: "#FFE45C"),
        Swatch(name: "Vàng kem", hex: "#F5E6B8"),
        Swatch(name: "Xanh nhạt", hex: "#8FD8FF"),
        Swatch(name: "Xanh lá", hex: "#A6F0A0"),
        Swatch(name: "Hồng", hex: "#FFB8CC"),
    ]

    static let sizeRange: ClosedRange<Double> = 12...30
    private static let defaults = (size: 16.0, colorHex: "#FFFFFF", font: FontChoice.system, bold: false, background: 0.65)

    @Published var size: Double { didSet { save(size, "sub_style_size") } }
    @Published var colorHex: String { didSet { save(colorHex, "sub_style_color") } }
    @Published var font: FontChoice { didSet { save(font.rawValue, "sub_style_font") } }
    @Published var bold: Bool { didSet { save(bold, "sub_style_bold") } }
    /// Opacity of the dark box behind the line; below 0.3 the letters get a dark outline instead.
    @Published var background: Double { didSet { save(background, "sub_style_background") } }

    /// Any change, for the player to pass on to VLC.
    let changed = PassthroughSubject<Void, Never>()

    var color: Color { Color(hex: colorHex) }
    var outlined: Bool { background < 0.3 }

    private init() {
        let stored = UserDefaults.standard
        size = stored.object(forKey: "sub_style_size") as? Double ?? Self.defaults.size
        colorHex = stored.string(forKey: "sub_style_color") ?? Self.defaults.colorHex
        font = FontChoice(rawValue: stored.string(forKey: "sub_style_font") ?? "") ?? Self.defaults.font
        bold = stored.object(forKey: "sub_style_bold") as? Bool ?? Self.defaults.bold
        background = stored.object(forKey: "sub_style_background") as? Double ?? Self.defaults.background
    }

    func reset() {
        size = Self.defaults.size
        colorHex = Self.defaults.colorHex
        font = Self.defaults.font
        bold = Self.defaults.bold
        background = Self.defaults.background
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        changed.send()
    }

    // MARK: - VLC

    /// VLC sizes text as a fraction of the video height (1/n of it). The app's line is in points on a screen about
    /// 390 pt tall in landscape, where a 16:9 video fills the height — so n = 390 / size looks about the same.
    /// (Left at 0, VLC makes it a tenth of the height: the "too big" default.)
    var vlcRelativeSize: Int { min(60, max(8, Int((390 / size).rounded()))) }

    var vlcColor: Int {
        var text = colorHex
        if text.hasPrefix("#") { text.removeFirst() }
        return Int(text, radix: 16) ?? 0xFFFFFF
    }

    /// The style as VLC text renderer settings (read on the main thread, applied on VLC's control queue).
    var vlcSettings: [(selector: String, value: NSObject)] {
        [
            ("setTextRendererFontSize:", NSNumber(value: vlcRelativeSize)),
            ("setTextRendererFontColor:", NSNumber(value: vlcColor)),
            ("setTextRendererFont:", font.vlcFamily as NSString),
            ("setTextRendererFontForceBold:", NSNumber(value: bold)),
        ]
    }

    /// VLCKit has these setters but does not declare them (VLC for iOS calls them the same way). They apply from the
    /// next line on, while playing.
    static func apply(_ settings: [(selector: String, value: NSObject)], to player: NSObject) {
        for (name, value) in settings {
            let selector = NSSelectorFromString(name)
            if player.responds(to: selector) { _ = player.perform(selector, with: value) }
        }
    }
}

/// One subtitle line in the chosen style — the player's overlay and the preview in the settings.
struct SubtitleLineView: View {
    let text: String
    @ObservedObject private var style = SubtitleStyle.shared

    var body: some View {
        Text(text)
            .multilineTextAlignment(.center)
            .font(style.font.font(size: style.size, bold: style.bold))
            .foregroundStyle(style.color)
            .shadow(color: .black.opacity(style.outlined ? 0.95 : 0), radius: 1)
            .shadow(color: .black.opacity(style.outlined ? 0.8 : 0), radius: 3)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.black.opacity(style.background))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// "Kiểu chữ phụ đề": preview, size, color, font, bold, background.
struct SubtitleStyleSection: View {
    @ObservedObject private var style = SubtitleStyle.shared
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)

    var body: some View {
        Section {
            ZStack {
                LinearGradient(colors: [Color(white: 0.35), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
                SubtitleLineView(text: "Phụ đề sẽ trông như thế này.\nXin chào, hôm nay thế nào?")
                    .padding(.horizontal, 8)
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Cỡ chữ")
                    Spacer()
                    Text("\(Int(style.size))").monospacedDigit().foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                    Slider(value: $style.size, in: SubtitleStyle.sizeRange, step: 1)
                    Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Màu chữ")
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(SubtitleStyle.swatches) { swatch in
                        let selected = style.colorHex.uppercased() == swatch.hex.uppercased()
                        Button {
                            style.colorHex = swatch.hex
                        } label: {
                            ZStack {
                                Circle().fill(Color(hex: swatch.hex)).frame(width: 34, height: 34)
                                    .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                                if selected {
                                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(swatch.name)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 4)
            ColorPicker("Màu khác…", selection: Binding(get: { style.color }, set: { style.colorHex = $0.hexString }),
                        supportsOpacity: false)

            Picker("Font chữ", selection: $style.font) {
                ForEach(SubtitleStyle.FontChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            Toggle("Chữ đậm", isOn: $style.bold)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Nền sau chữ")
                    Spacer()
                    Text(style.outlined ? "Không nền · viền chữ" : "\(Int((style.background * 100).rounded()))%")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $style.background, in: 0...0.9, step: 0.05)
            }

            Button("Về mặc định") { style.reset() }
        } header: {
            Text("Kiểu chữ phụ đề")
        } footer: {
            Text("Áp dụng cho phụ đề AI, phụ đề tải từ OpenSubtitles (hiện như phụ đề AI) và phụ đề có sẵn trong file. Phụ đề có sẵn do VLC vẽ: theo cỡ chữ, màu, font và chữ đậm (không có nền, luôn có viền); phụ đề kiểu ASS (thường gặp ở anime) có định dạng riêng trong file nên có thể không đổi.")
        }
    }
}

/// "Kiểu chữ phụ đề   Cỡ 16 · SF (mặc định)" — the row that opens the style page.
struct SubtitleStyleSummary: View {
    @ObservedObject private var style = SubtitleStyle.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "textformat").foregroundStyle(.tint).frame(width: 24)
            Text("Kiểu chữ phụ đề")
            Spacer(minLength: 8)
            Circle().fill(style.color).frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
            Text("Cỡ \(Int(style.size)) · \(style.font.label)").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// The style section on its own page (from the player's subtitle sheet and from Cài đặt).
struct SubtitleStyleView: View {
    var body: some View {
        List { SubtitleStyleSection() }
            .navigationTitle("Kiểu chữ phụ đề")
            .navigationBarTitleDisplayMode(.inline)
    }
}
