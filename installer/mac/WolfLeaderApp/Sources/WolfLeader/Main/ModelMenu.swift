import SwiftUI

/// Picks the model and effort level for a chat. Shown only for agents that support it.
struct ModelMenu: View {
    let agent: AgentKind?
    let model: String?
    let effort: String?
    let choose: (_ model: String?, _ effort: String?) -> Void
    var font: Font = DS.Font.caption.weight(.semibold)

    @ObservedObject private var catalog = ModelCatalog.shared

    var body: some View {
        if ModelCatalog.supports(agent) {
            Menu {
                Section("Model") {
                    item("Default", checked: model == nil) { choose(nil, keptEffort(for: nil)) }
                    ForEach(catalog.models(for: agent)) { option in
                        item(option.name, checked: model == option.id) { choose(option.id, keptEffort(for: option.id)) }
                    }
                }
                Section("Effort") {
                    item("Default", checked: effort == nil) { choose(model, nil) }
                    ForEach(catalog.efforts(for: agent, model: model), id: \.self) { level in
                        item(ModelCatalog.effortName(level), checked: effort == level) { choose(model, level) }
                    }
                }
            } label: {
                Label(catalog.label(agent: agent, model: model, effort: effort), systemImage: "cpu")
                    .font(font)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Which model this chat uses, and how hard it thinks. Default leaves it to \(agent?.name ?? "the AI")'s own settings.")
            .onAppear { catalog.loadCodexIfNeeded() }
        }
    }

    /// Keep the effort when switching models, unless the new model doesn't offer it.
    private func keptEffort(for newModel: String?) -> String? {
        guard let effort else { return nil }
        return catalog.efforts(for: agent, model: newModel).contains(effort) ? effort : nil
    }

    @ViewBuilder
    private func item(_ title: String, checked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

/// The model and effort new chats start with, remembered per agent.
enum ModelDefaults {
    static func model(_ agentID: String) -> String? { UserDefaults.standard.string(forKey: "wl.chat.model.\(agentID)") }
    static func effort(_ agentID: String) -> String? { UserDefaults.standard.string(forKey: "wl.chat.effort.\(agentID)") }

    static func set(_ agentID: String, model: String?, effort: String?) {
        UserDefaults.standard.set(model, forKey: "wl.chat.model.\(agentID)")
        UserDefaults.standard.set(effort, forKey: "wl.chat.effort.\(agentID)")
    }
}
