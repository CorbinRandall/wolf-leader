import AppKit
import SwiftUI

/// Title + one line under it, at the top of every setup step.
struct SetupHeader: View {
    @Environment(\.palette) private var p
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(p.text)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(p.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 8)
    }
}

/// A selectable choice: bold title, one sentence, small grey example.
struct SetupChoiceCard: View {
    @Environment(\.palette) private var p
    let title: String
    let detail: String
    let example: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Card {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 17))
                        .foregroundStyle(selected ? p.accent : p.textMuted)
                        .padding(.top, 1)
                    SetupCardText(title: title, detail: detail, example: example)
                    Spacer(minLength: 0)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? p.accent : Color.clear, lineWidth: 2)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// An on/off option in the same card shape.
struct SetupToggleCard: View {
    @Environment(\.palette) private var p
    let title: String
    let detail: String
    let example: String
    @Binding var isOn: Bool

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 14) {
                SetupCardText(title: title, detail: detail, example: example)
                    .contentShape(Rectangle())
                    .onTapGesture { isOn.toggle() }
                Spacer(minLength: 8)
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }
}

struct SetupCardText: View {
    @Environment(\.palette) private var p
    let title: String
    let detail: String
    let example: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(p.text)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(p.text.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            if !example.isEmpty {
                Text(example)
                    .font(.system(size: 12))
                    .foregroundStyle(p.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum SetupNoticeKind {
    case good, warn, bad, info
}

/// A one-to-three line coloured note (no pop-ups anywhere in setup).
struct SetupNotice: View {
    @Environment(\.palette) private var p
    let kind: SetupNoticeKind
    let text: String

    private var color: Color {
        switch kind {
        case .good: return p.good
        case .warn: return p.warn
        case .bad: return p.bad
        case .info: return p.accent
        }
    }

    private var symbol: String {
        switch kind {
        case .good: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.system(size: 14))
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(p.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(color.opacity(0.35)))
    }
}

/// A shell command with a Copy button.
struct SetupCommandRow: View {
    @Environment(\.palette) private var p
    let command: String

    var body: some View {
        HStack(spacing: 10) {
            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(p.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            SetupCopyButton(text: command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(p.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(p.border))
    }
}

struct SetupCopyButton: View {
    let text: String
    var label = "Copy"
    var prominent = false
    @State private var copied = false

    init(text: String, label: String = "Copy", prominent: Bool = false) {
        self.text = text
        self.label = label
        self.prominent = prominent
    }

    var body: some View {
        Group {
            if prominent {
                Button(action: copy) { buttonLabel }
                    .buttonStyle(PrimaryButtonStyle())
            } else {
                Button(action: copy) { buttonLabel }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var buttonLabel: some View {
        Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
    }

    private func copy() {
        SetupClipboard.copy(text)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            copied = false
        }
    }
}

enum SetupClipboard {
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static var text: String? { NSPasteboard.general.string(forType: .string) }
}

/// Label/value line for the Review step.
struct SetupSummaryRow: View {
    @Environment(\.palette) private var p
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(p.textMuted)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(p.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension SetupPath {
    var setupTitle: String {
        switch self {
        case .connectExisting: return "Wolf Leader already runs on another computer"
        case .updateThisMac: return "Wolf Leader is already on this Mac"
        case .newOnServer: return "I'm new — host it on an always-on computer (recommended)"
        case .newOnThisMac: return "I'm new — host it on this Mac (experimental)"
        }
    }

    var setupShortLabel: String {
        switch self {
        case .connectExisting: return "Connect this Mac to your hub"
        case .updateThisMac: return "Update Wolf Leader on this Mac"
        case .newOnServer: return "New hub on an always-on computer"
        case .newOnThisMac: return "New hub on this Mac (Docker, experimental)"
        }
    }
}
