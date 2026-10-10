import SwiftUI

/// Layout tokens shared by every screen (MacParakeet scale).
enum DS {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    enum Font {
        static let hero = SwiftUI.Font.system(size: 28, weight: .bold, design: .rounded)
        static let page = SwiftUI.Font.system(size: 22, weight: .semibold, design: .rounded)
        static let section = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let bodyLarge = SwiftUI.Font.system(size: 15)
        static let body = SwiftUI.Font.system(size: 14)
        static let bodySmall = SwiftUI.Font.system(size: 13)
        static let caption = SwiftUI.Font.system(size: 12)
        static let micro = SwiftUI.Font.system(size: 11)
        static let label = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let stat = SwiftUI.Font.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit()
        static let timestamp = SwiftUI.Font.system(size: 12).monospacedDigit()
    }

    enum Radius {
        static let card: CGFloat = 14
        static let row: CGFloat = 10
        static let badge: CGFloat = 9
        static let sidebar: CGFloat = 16
    }

    enum Anim {
        static let select: Animation = .easeInOut(duration: 0.15)
        static let hover: Animation = .easeInOut(duration: 0.12)
        static let swap: Animation = .easeInOut(duration: 0.2)
    }
}

extension View {
    /// Standard card container: surface fill, hairline border, soft shadow.
    func wlCardSurface(radius: CGFloat = DS.Radius.card) -> some View {
        modifier(CardSurface(radius: radius))
    }

    /// Accent-tinted switch.
    func wlSwitch() -> some View {
        modifier(AccentSwitch())
    }
}

private struct CardSurface: ViewModifier {
    @Environment(\.palette) private var p
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(p.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(p.border.opacity(0.7), lineWidth: 0.6))
            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
    }
}

private struct AccentSwitch: ViewModifier {
    @Environment(\.palette) private var p

    func body(content: Content) -> some View {
        content.toggleStyle(.switch).tint(p.accent).labelsHidden()
    }
}

/// Page title + one-line explanation at the top of a screen.
struct WLPageHeader<Trailing: View>: View {
    @Environment(\.palette) private var p
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(DS.Font.page).foregroundStyle(p.text)
                if let subtitle {
                    Text(subtitle).font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
                }
            }
            Spacer(minLength: DS.Spacing.md)
            trailing()
        }
    }
}

extension WLPageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

/// Small uppercase label above a group, e.g. "CAPTURE WORKFLOW".
struct WLSectionLabel: View {
    @Environment(\.palette) private var p
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(DS.Font.label)
            .tracking(0.6)
            .foregroundStyle(p.textMuted)
    }
}

/// Rounded square with an SF Symbol, used at the left of group headers and rows.
struct WLIconBadge: View {
    @Environment(\.palette) private var p
    let systemName: String
    var tint: Color? = nil
    var size: CGFloat = 34

    var body: some View {
        let color = tint ?? p.accent
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous))
    }
}

enum WLStatusKind {
    case good, warn, bad, neutral
}

/// Compact status chip, e.g. "Connected" in green.
struct WLStatusPill: View {
    @Environment(\.palette) private var p
    let text: String
    var kind: WLStatusKind = .good

    var body: some View {
        let color: Color = {
            switch kind {
            case .good: return p.good
            case .warn: return p.warn
            case .bad: return p.bad
            case .neutral: return p.textMuted
            }
        }()
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// A settings-style card: optional icon + title + subtitle header, then rows.
/// Put `WLDivider()` between rows.
struct WLGroup<Content: View>: View {
    @Environment(\.palette) private var p
    var title: String? = nil
    var subtitle: String? = nil
    var icon: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            if title != nil || icon != nil {
                HStack(spacing: 12) {
                    if let icon { WLIconBadge(systemName: icon) }
                    VStack(alignment: .leading, spacing: 2) {
                        if let title { Text(title).font(DS.Font.section).foregroundStyle(p.text) }
                        if let subtitle { Text(subtitle).font(DS.Font.bodySmall).foregroundStyle(p.textMuted) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wlCardSurface()
    }
}

struct WLDivider: View {
    @Environment(\.palette) private var p

    var body: some View {
        Rectangle().fill(p.border).frame(height: 1)
    }
}

/// Title + grey explanation on the left, a control on the right.
struct WLRow<Control: View>: View {
    @Environment(\.palette) private var p
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(DS.Font.body).foregroundStyle(p.text)
                if let detail {
                    Text(detail)
                        .font(DS.Font.caption)
                        .foregroundStyle(p.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Spacing.md)
            control()
        }
    }
}

/// One tab in `WLTabBar`.
struct WLTab<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    var icon: String? = nil
    /// Shows a small dot (e.g. "update available").
    var attention: Bool = false
}

/// Capsule tab strip like MacParakeet's Settings header.
struct WLTabBar<ID: Hashable>: View {
    @Environment(\.palette) private var p
    let tabs: [WLTab<ID>]
    @Binding var selection: ID

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                let selected = tab.id == selection
                Button {
                    withAnimation(DS.Anim.select) { selection = tab.id }
                } label: {
                    HStack(spacing: 6) {
                        if let icon = tab.icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
                        Text(tab.title).font(.system(size: 13, weight: selected ? .semibold : .medium))
                        if tab.attention { Circle().fill(p.bad).frame(width: 6, height: 6) }
                    }
                    .foregroundStyle(selected ? p.text : p.textMuted)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(selected ? p.surfaceRaised : Color.clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(p.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(p.border, lineWidth: 0.5))
    }
}

/// Rounded search box.
struct WLSearchField: View {
    @Environment(\.palette) private var p
    @Binding var text: String
    var placeholder: String = "Search"
    var large = false
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: large ? 16 : 13, weight: .medium))
                .foregroundStyle(p.textMuted)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(large ? DS.Font.bodyLarge : DS.Font.bodySmall)
                .foregroundStyle(p.text)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(p.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, large ? 13 : 8)
        .background(p.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(p.border, lineWidth: 0.5))
    }
}

/// Sidebar entry: icon + label, filled accent pill when selected.
struct WLSidebarRow: View {
    @Environment(\.palette) private var p
    let title: String
    let icon: String
    let selected: Bool
    /// Small red dot on the right (e.g. update available).
    var attention = false
    let action: () -> Void
    @State private var hovering = false

    init(title: String, icon: String, selected: Bool, attention: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.selected = selected
        self.attention = attention
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                Text(title).font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer()
                if attention { Circle().fill(selected ? p.onAccent : p.bad).frame(width: 7, height: 7) }
            }
            .foregroundStyle(selected ? p.onAccent : p.text)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous)
                    .fill(selected ? p.accent : (hovering ? p.surfaceRaised.opacity(0.6) : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.Anim.hover) { hovering = h } }
    }
}

/// Selectable card (MacParakeet's Dictation / Transcription / Meetings picker).
/// Used for setup choices: bold title, one sentence, small example line.
struct WLChoiceCard: View {
    @Environment(\.palette) private var p
    let title: String
    var detail: String? = nil
    var example: String? = nil
    var icon: String? = nil
    var badge: String? = nil
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    init(
        title: String, detail: String? = nil, example: String? = nil, icon: String? = nil,
        badge: String? = nil, selected: Bool, action: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.example = example
        self.icon = icon
        self.badge = badge
        self.selected = selected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                if let icon { WLIconBadge(systemName: icon, tint: selected ? p.accent : p.textMuted) }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.text)
                        if let badge { WLStatusPill(text: badge, kind: .warn) }
                    }
                    if let detail {
                        Text(detail).font(DS.Font.bodySmall).foregroundStyle(p.text.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let example {
                        Text(example).font(DS.Font.caption).foregroundStyle(p.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? p.accent : p.textFaint)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(selected ? p.accent.opacity(0.12) : (hovering ? p.surfaceRaised : p.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(selected ? p.accent.opacity(0.8) : p.border.opacity(0.7), lineWidth: selected ? 1 : 0.6)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.Anim.hover) { hovering = h } }
    }
}

/// Big number tile for the Home stats panel.
struct WLStatTile: View {
    @Environment(\.palette) private var p
    let title: String
    let value: String
    let icon: String
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                WLIconBadge(systemName: icon, tint: p.accent, size: 28)
                Spacer()
            }
            Text(value).font(DS.Font.stat).foregroundStyle(p.text)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
                if let footnote { Text(footnote).font(DS.Font.micro).foregroundStyle(p.textMuted.opacity(0.8)) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wlCardSurface()
    }
}
