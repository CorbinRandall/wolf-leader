import SwiftUI

/// Settings > Rules: what holds for every chat, with every agent, on every device.
struct ChatRulesSettings: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var store: ConfigStore
    @EnvironmentObject private var nav: Navigator
    @ObservedObject private var rules = ChatRules.shared
    @State private var draft = ""
    @State private var editing = false

    var body: some View {
        WLGroup(title: "Permissions", subtitle: "Applies to every chat, with every agent, on every device.", icon: "bolt.shield") {
            WLRow(title: "Never ask",
                  detail: "Agents act without asking: every chat runs in Full auto, and anything an agent still asks about is approved for good, on the spot.") {
                Toggle("Never ask", isOn: Binding(
                    get: { rules.neverAsk },
                    set: { on in rules.update { $0.never_ask = on; if on { $0.default_mode = "auto" } } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            if !rules.neverAsk {
                WLDivider()
                WLRow(title: "New chats start in", detail: "You can still change it per chat from the chat's header.") {
                    Picker("New chats start in", selection: Binding(
                        get: { rules.value.default_mode },
                        set: { mode in rules.update { $0.default_mode = mode } }
                    )) {
                        ForEach(PermissionMode.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
            }
        }

        WLGroup(title: "Wolf Leader in every chat", icon: "magnifyingglass.circle") {
            WLRow(title: "Let AIs look things up and take notes",
                  detail: "Every chat gets Wolf Leader's tools: search your projects, memories and past chats mid-conversation, and record decisions or things about you. Saving the chat stays with Wolf Leader.") {
                Toggle("Wolf Leader tools", isOn: Binding(
                    get: { rules.hubTools },
                    set: { on in rules.update { $0.hub_tools = on } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
        }

        WLGroup(title: "Rules for every chat",
                subtitle: "Every agent gets these at the start of every chat: how you like to work, what to always or never do.",
                icon: "text.badge.checkmark") {
            TextEditor(text: $draft)
                .font(DS.Font.bodySmall)
                .frame(minHeight: 120)
                .padding(6)
                .background(p.background, in: RoundedRectangle(cornerRadius: DS.Radius.row))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.row).strokeBorder(p.border.opacity(0.7), lineWidth: 0.6))
                .onChange(of: draft) { _, new in editing = new != rules.value.rules }
            HStack {
                if draft.isEmpty {
                    Text("e.g. Keep replies short. Use plain English. Commit after each working change. Never push to main.")
                        .font(DS.Font.caption).foregroundStyle(p.textFaint)
                }
                Spacer(minLength: 0)
                Button("Save rules") { rules.update { $0.rules = draft }; editing = false }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!editing)
            }
        }

        WLGroup(title: "Skills in every chat", icon: "shippingbox") {
            WLRow(title: rules.value.skills.isEmpty ? "None yet" : rules.value.skills.joined(separator: ", "),
                  detail: "Choose them in Library > Skills, where your skills live.") {
                Button("Open Skills") { nav.open(libraryTab: "skills") }.buttonStyle(OutlineButtonStyle())
            }
        }

        if let problem = rules.problem {
            Text(problem).font(DS.Font.caption).foregroundStyle(p.bad)
        }

        Color.clear.frame(height: 0)
            .task {
                draft = rules.value.rules
                await rules.refresh()
                if !editing { draft = rules.value.rules }
            }
    }

}
