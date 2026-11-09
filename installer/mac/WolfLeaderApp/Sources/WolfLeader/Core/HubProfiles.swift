import AppKit
import SwiftUI

struct HubProfile: Identifiable, Codable, Equatable {
    var id = UUID().uuidString
    var name: String
    var hubURL: String
    var mcpURL: String
    var sshHost: String
    /// nil preserves the existing installation's chat and project folders.
    var storageID: String?
    var person: String?

    func workspaceDirectory(base: URL) -> URL {
        guard let storageID, UUID(uuidString: storageID) != nil else { return base }
        return base.appendingPathComponent("hubs").appendingPathComponent(storageID)
    }
}

extension ConfigStore {
    func ensureHubProfiles() {
        guard config.hubProfiles == nil || config.hubProfiles?.isEmpty == true else { return }
        let profile = HubProfile(name: "Current hub", hubURL: config.hubURL, mcpURL: config.mcpURL,
                                 sshHost: UserDefaults.standard.string(forKey: "wl.serverSSHHost") ?? "wolf",
                                 person: config.person)
        config.hubProfiles = [profile]
        config.activeHubProfileID = profile.id
        save()
    }

    @MainActor func switchHub(_ profile: HubProfile) {
        guard profile.id != config.activeHubProfileID else { return }
        // Do not interrupt an agent or let an in-flight save land in another hub.
        guard !ChatStore.shared.records.contains(where: { ChatStore.shared.isRunning($0.id) }) else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 2; /usr/bin/open -n \"$1\"", "wolf-reopen", Bundle.main.bundlePath]
        do { try task.run() } catch { return }
        config.activeHubProfileID = profile.id
        config.hubURL = profile.hubURL
        config.mcpURL = profile.mcpURL
        config.person = profile.person
        UserDefaults.standard.set(profile.sshHost, forKey: "wl.serverSSHHost")
        save()
        NSApplication.shared.terminate(nil)
    }
}

struct HubSwitcher: View {
    @EnvironmentObject var store: ConfigStore
    @ObservedObject private var chats = ChatStore.shared
    private var busy: Bool { chats.records.contains { chats.isRunning($0.id) } }
    var body: some View {
        Menu {
            ForEach(store.config.hubProfiles ?? []) { profile in
                Button(profile.name + (profile.id == store.config.activeHubProfileID ? " ✓" : "")) {
                    store.switchHub(profile)
                }
            }
        } label: {
            Label(store.config.hubProfiles?.first(where: { $0.id == store.config.activeHubProfileID })?.name ?? "Switch hub",
                  systemImage: "server.rack")
        }
        .disabled(busy)
        .help(busy ? "Wait for chats to finish before switching hubs." : "Switch hub and reopen Wolf Leader. Chats stay with their hub.")
        .onAppear { store.ensureHubProfiles() }
    }
}

struct HubProfileEditor: View {
    @EnvironmentObject var store: ConfigStore
    @State private var name = ""
    @State private var hub = ""
    @State private var mcp = ""
    @State private var ssh = ""
    private var valid: Bool {
        [hub, mcp].allSatisfy {
            guard let url = URL(string: $0), let scheme = url.scheme else { return false }
            return ["http", "https"].contains(scheme) && url.host != nil && url.user == nil && url.password == nil
        } && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HubSwitcher()
            Text("Switching reopens the app. Each hub has its own chats and project copies.").font(.caption)
            DisclosureGroup("Save another hub") {
                TextField("Name", text: $name)
                TextField("Hub URL", text: $hub)
                TextField("MCP URL", text: $mcp)
                TextField("SSH host (optional)", text: $ssh)
                Button("Save hub") {
                    let profile = HubProfile(name: name, hubURL: hub, mcpURL: mcp, sshHost: ssh,
                                             storageID: UUID().uuidString)
                    store.config.hubProfiles = (store.config.hubProfiles ?? []) + [profile]
                    store.save()
                    name = ""; hub = ""; mcp = ""; ssh = ""
                }.disabled(!valid)
            }
        }
    }
}
