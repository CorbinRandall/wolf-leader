import SwiftUI

/// Settings > Rules: what holds for every chat, with every agent, on every device.
struct ChatRulesSettings: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var store: ConfigStore
    @ObservedObject private var rules = ChatRules.shared
    @State private var draft = ""
    @State private var editing = false
    @State private var descriptions: [String: String] = [:]

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

        WLGroup(title: "Skills in every chat",
                subtitle: "Skills from your Library that every chat starts with, whichever agent runs it.",
                icon: "shippingbox") {
            if rules.library.isEmpty {
                Text("No skills in your Library yet.").font(DS.Font.caption).foregroundStyle(p.textMuted)
            }
            ForEach(Array(rules.library.enumerated()), id: \.element) { index, name in
                if index > 0 { WLDivider() }
                WLRow(title: name, detail: descriptions[name]) {
                    Toggle(name, isOn: Binding(
                        get: { rules.value.skills.contains(name) },
                        set: { on in
                            rules.update { value in
                                value.skills.removeAll { $0 == name }
                                if on { value.skills.append(name) }
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
            if ["wolfhowl", "wolfeat"].contains(where: rules.library.contains) {
                Text("wolfhowl and wolfeat aren't needed here: Wolf Leader chats save themselves and start with the project's context.")
                    .font(DS.Font.caption).foregroundStyle(p.textMuted)
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
                await loadDescriptions()
            }
    }

    private func loadDescriptions() async {
        guard let data = try? await store.hub.data("/api/skills"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skills = json["skills"] as? [[String: Any]] else { return }
        var out: [String: String] = [:]
        for skill in skills {
            if let name = skill["name"] as? String { out[name] = AgentText.oneLine(skill["description"] as? String ?? "", limit: 180) }
        }
        descriptions = out
    }
}
