import Foundation
import SwiftUI

/// Keeps ~/.claude/skills (and sibling tool dirs) in sync with the hub's master set automatically.
/// Runs a push-skills whenever the hub has skill names that differ from what's on disk.
@MainActor
final class SkillSyncer: ObservableObject {
    @Published private(set) var lastSyncedAt: Date?

    static let shared = SkillSyncer()
    private init() {}

    private static let checkInterval: Duration = .seconds(300)
    private static let skillsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/skills")

    static func fingerprint() -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: skillsDir.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().joined(separator: ",")
    }

    func start(store: ConfigStore) {
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.checkAndSync(store: store)
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    private func checkAndSync(store: ConfigStore) async {
        guard let response = try? await store.hub.skills() else { return }
        let hubNames = Set(response.skills.map(\.id))
        let localNames = Set((try? FileManager.default.contentsOfDirectory(atPath: Self.skillsDir.path))?.filter { !$0.hasPrefix(".") } ?? [])
        guard hubNames != localNames else {
            lastSyncedAt = Date()
            return
        }
        guard let script = ToolBridge.script else { return }
        let run = await MainProcess.run("/usr/bin/python3", [script.path, "push-skills", "--api", store.config.hubURL])
        if run.code == 0 { lastSyncedAt = Date() }
    }
}
