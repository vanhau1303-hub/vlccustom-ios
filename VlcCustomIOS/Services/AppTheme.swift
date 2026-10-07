import SwiftUI
import UIKit

/// The app's look: the main ("chủ đạo") color and light / dark mode, chosen in Cài đặt → Giao diện. Applied at the
/// root with `.tint` (views draw their accents with the `.tint` shape style, so they follow a change at once) and
/// on the UIKit windows (alerts, menus, sheets presented by UIKit).
final class AppTheme: ObservableObject {
    static let shared = AppTheme()

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return "Theo máy"
            case .light: return "Sáng"
            case .dark: return "Tối"
            }
        }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    struct Preset: Identifiable {
        let name: String
        let hex: String
        var id: String { hex }
        var color: Color { Color(hex: hex) }
    }

    static let presets: [Preset] = [
        Preset(name: "Xanh dương", hex: "#0A84FF"),
        Preset(name: "Chàm", hex: "#5E5CE6"),
        Preset(name: "Tím", hex: "#BF5AF2"),
        Preset(name: "Hồng", hex: "#FF375F"),
        Preset(name: "Đỏ", hex: "#FF453A"),
        Preset(name: "Cam", hex: "#FF9F0A"),
        Preset(name: "Vàng", hex: "#FFCC00"),
        Preset(name: "Xanh lá", hex: "#30D158"),
        Preset(name: "Bạc hà", hex: "#00C7BE"),
        Preset(name: "Xanh ngọc", hex: "#40C8E0"),
    ]

    private static let accentKey = "theme_accent"
    private static let appearanceKey = "theme_appearance"

    @Published var accentHex: String {
        didSet {
            UserDefaults.standard.set(accentHex, forKey: Self.accentKey)
            applyToWindows()
        }
    }
    @Published var appearance: Appearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey)
            applyToWindows()
        }
    }

    var accent: Color { Color(hex: accentHex) }
    var colorScheme: ColorScheme? { appearance.colorScheme }

    private init() {
        let env = ProcessInfo.processInfo.environment
        // CI screenshots: DEMO_ACCENT / DEMO_APPEARANCE pick the look for the run.
        accentHex = env["DEMO_ACCENT"] ?? UserDefaults.standard.string(forKey: Self.accentKey) ?? Self.presets[0].hex
        appearance = Appearance(rawValue: env["DEMO_APPEARANCE"] ?? UserDefaults.standard.string(forKey: Self.appearanceKey) ?? "")
            ?? .system
    }

    /// UIKit-presented things (alerts, action sheets, share sheet) follow the theme too.
    func applyToWindows() {
        let tint = UIColor(accent)
        let style: UIUserInterfaceStyle = appearance == .light ? .light : appearance == .dark ? .dark : .unspecified
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] {
                window.tintColor = tint
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    func setAccent(_ color: Color) {
        accentHex = color.hexString
    }
}

extension Color {
    /// "#RRGGBB".
    init(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        let value = UInt32(text, radix: 16) ?? 0x0A84FF
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

/// A rounded, colored square behind a white symbol — the iOS Settings look for list rows.
struct SettingsIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.gradient))
    }
}

/// A list row label with a `SettingsIcon`.
struct IconLabel: View {
    let title: String
    let systemName: String
    let color: Color

    init(_ title: String, systemName: String, color: Color) {
        self.title = title
        self.systemName = systemName
        self.color = color
    }

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemName: systemName, color: color)
            Text(title).foregroundStyle(.primary)
        }
    }
}

/// Cài đặt → Giao diện: main color (swatches + any color) and light / dark.
struct ThemeSettingsSection: View {
    @ObservedObject private var theme = AppTheme.shared
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Màu chủ đạo").font(.subheadline.weight(.medium))
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(AppTheme.presets) { preset in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { theme.accentHex = preset.hex }
                        } label: {
                            ZStack {
                                Circle().fill(preset.color.gradient).frame(width: 38, height: 38)
                                if theme.accentHex.uppercased() == preset.hex.uppercased() {
                                    Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                                }
                            }
                            .overlay(Circle().stroke(Color.primary.opacity(theme.accentHex.uppercased() == preset.hex.uppercased() ? 0.35 : 0), lineWidth: 2).padding(-4))
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(preset.name)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 6)
            ColorPicker(selection: Binding(get: { theme.accent }, set: { theme.setAccent($0) }), supportsOpacity: false) {
                IconLabel("Màu khác…", systemName: "paintpalette.fill", color: theme.accent)
            }
            Picker(selection: $theme.appearance) {
                ForEach(AppTheme.Appearance.allCases) { Text($0.label).tag($0) }
            } label: {
                IconLabel("Chế độ", systemName: "circle.lefthalf.filled", color: .gray)
            }
        } header: {
            Text("Giao diện")
        }
    }
}
