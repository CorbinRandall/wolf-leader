import SwiftUI

enum ThemeID: String, CaseIterable, Identifiable, Codable {
    case system, wolf, parakeet, halo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Follow System"
        case .wolf: return "Wolf"
        case .parakeet: return "Parakeet"
        case .halo: return "Halo"
        }
    }

    var blurb: String {
        switch self {
        case .system: return "Parakeet, light or dark to match your Mac."
        case .wolf: return "Deep navy with a blue glow, like the icon."
        case .parakeet: return "Charcoal with warm coral buttons. Always dark."
        case .halo: return "Light cream paper with pastel accents."
        }
    }

    static let `default`: ThemeID = .system
}

/// Color roles. Parakeet values are MacParakeet's DesignSystem tokens verbatim.
struct Palette {
    var scheme: ColorScheme
    /// Window / detail background.
    var background: Color
    /// Only used where a solid sidebar is needed; the main sidebar is native glass.
    var sidebar: Color
    /// Settings-style cards (radius 14).
    var surface: Color
    /// Big tiles (radius 20), hover rows, secondary capsules.
    var surfaceRaised: Color
    var border: Color
    var divider: Color
    var text: Color
    var textMuted: Color
    var textFaint: Color
    /// Selection, links, primary buttons, outline capsules.
    var accent: Color
    /// Secondary highlight (permission / attention buttons).
    var accent2: Color
    var onAccent: Color
    var good: Color
    var warn: Color
    var bad: Color

    static let parakeetDark = Palette(
        scheme: .dark,
        background: Color(hex: 0x1C1C1F), sidebar: Color(hex: 0x1C1C1F),
        surface: Color(hex: 0x2B2B2E), surfaceRaised: Color(hex: 0x3B3B3D),
        border: Color(hex: 0x4D4D52), divider: Color(hex: 0x404045),
        text: .white, textMuted: Color(hex: 0xA1A1A6), textFaint: Color(hex: 0x636366),
        accent: Color(hex: 0xFF8A5C), accent2: Color(hex: 0xFABF24), onAccent: .white,
        good: Color(hex: 0x4ADE80), warn: Color(hex: 0xFABF24), bad: Color(hex: 0xF87171)
    )

    static let parakeetLight = Palette(
        scheme: .light,
        background: Color(hex: 0xFAFAF7), sidebar: Color(hex: 0xF5F5F0),
        surface: .white, surfaceRaised: Color(hex: 0xF5F5F0),
        border: Color(hex: 0xE8E8E0), divider: Color(hex: 0xF0F0E8),
        text: Color(hex: 0x1A1A1A), textMuted: Color(hex: 0x6B6B6B), textFaint: Color(hex: 0x9C9C9C),
        accent: Color(hex: 0xE86B3B), accent2: Color(hex: 0xF5A624), onAccent: .white,
        good: Color(hex: 0x33A854), warn: Color(hex: 0xF5A624), bad: Color(hex: 0xE64D42)
    )

    static let parakeet = parakeetDark

    static let wolf = Palette(
        scheme: .dark,
        background: Color(hex: 0x0E1624), sidebar: Color(hex: 0x0A1019),
        surface: Color(hex: 0x15223A), surfaceRaised: Color(hex: 0x1C2C49),
        border: Color.white.opacity(0.10), divider: Color.white.opacity(0.06),
        text: Color(hex: 0xE8EEF8), textMuted: Color(hex: 0x8A9BB5), textFaint: Color(hex: 0x5A6A85),
        accent: Color(hex: 0x6FA8FF), accent2: Color(hex: 0xE3B04B), onAccent: .white,
        good: Color(hex: 0x5CC8A0), warn: Color(hex: 0xE3B04B), bad: Color(hex: 0xE06C75)
    )

    static let halo = Palette(
        scheme: .light,
        background: Color(hex: 0xEAE3DA), sidebar: Color(hex: 0xF0EBE2),
        surface: Color(hex: 0xF5F1E9), surfaceRaised: Color(hex: 0xFBF8F3),
        border: Color(red: 29 / 255, green: 25 / 255, blue: 22 / 255).opacity(0.10),
        divider: Color(red: 29 / 255, green: 25 / 255, blue: 22 / 255).opacity(0.06),
        text: Color(hex: 0x1D1916), textMuted: Color(hex: 0x6E675E), textFaint: Color(hex: 0x9A9288),
        accent: Color(hex: 0x6C7FD1), accent2: Color(hex: 0x47997A), onAccent: .white,
        good: Color(hex: 0x47997A), warn: Color(hex: 0xC79A2E), bad: Color(hex: 0xD9647F)
    )
}

final class ThemeStore: ObservableObject {
    private static let key = "wl.theme"

    @Published var themeID: ThemeID {
        didSet { UserDefaults.standard.set(themeID.rawValue, forKey: Self.key) }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.key) ?? ""
        themeID = ThemeID(rawValue: saved) ?? .default
    }

    /// Pass the view's `@Environment(\.colorScheme)` so Follow System can pick a side.
    func palette(for systemScheme: ColorScheme) -> Palette {
        Self.palette(for: themeID, systemScheme: systemScheme)
    }

    static func palette(for id: ThemeID, systemScheme: ColorScheme) -> Palette {
        switch id {
        case .system: return systemScheme == .dark ? .parakeetDark : .parakeetLight
        case .wolf: return .wolf
        case .parakeet: return .parakeet
        case .halo: return .halo
        }
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.parakeetDark
}

extension EnvironmentValues {
    /// The active palette. Read it with `@Environment(\.palette) private var p`.
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Settings-style card: `surface`, radius 14, hairline border (MacParakeet `cardSurface`).
struct Card<Content: View>: View {
    @Environment(\.palette) private var p
    var padding: CGFloat = 20
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.border.opacity(0.7), lineWidth: 0.6))
            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
    }
}

/// Solid accent button, rounded rect radius 8 (MacParakeet "Test Input").
/// `warm` swaps to `accent2`.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.palette) private var p
    var warm = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(p.onAccent)
            .background(warm ? p.accent2 : p.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Neutral capsule: raised grey with a hairline border (MacParakeet "Change…" / "Paste").
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.palette) private var p

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(p.text)
            .background(p.surfaceRaised.opacity(0.7), in: Capsule())
            .overlay(Capsule().strokeBorder(p.border.opacity(0.7), lineWidth: 0.6))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Tinted outline capsule that fills solid on hover and lifts 1.03
/// (MacParakeet "Browse Files" / "Enable"). Defaults to `accent`.
struct OutlineButtonStyle: ButtonStyle {
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        OutlineButtonBody(configuration: configuration, tint: tint)
    }
}

private struct OutlineButtonBody: View {
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyleConfiguration
    let tint: Color?
    @State private var hovering = false

    var body: some View {
        let color = tint ?? p.accent
        let lit = hovering && isEnabled
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(lit ? p.onAccent : color)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(lit ? color : color.opacity(0.10)))
            .overlay(Capsule().strokeBorder(color.opacity(lit ? 0 : 0.45), lineWidth: 0.8))
            .scaleEffect(configuration.isPressed ? 0.98 : (lit ? 1.03 : 1))
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.15), value: lit)
            .onHover { hovering = $0 }
    }
}

/// Big content tile: `surfaceRaised`, radius 20, hairline border, soft shadow
/// (MacParakeet Transcribe / Drop a file / Enable meeting recording tiles).
struct Tile<Content: View>: View {
    @Environment(\.palette) private var p
    var padding: CGFloat = 24
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.surfaceRaised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(p.border.opacity(0.7), lineWidth: 0.6))
            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
    }
}
