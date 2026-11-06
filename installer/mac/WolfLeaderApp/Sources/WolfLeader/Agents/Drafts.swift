import AppKit
import Foundation

/// Text typed into a chat but not sent yet, kept per chat (and one for the new-chat page), so
/// leaving the page, switching chats or quitting the app doesn't lose it.
@MainActor
final class Drafts: ObservableObject {
    static let shared = Drafts()
    /// The new-chat page's box.
    static let newChat = "new-chat"

    private static let key = "wl.chat.drafts"
    private var all: [String: String]
    private var saveTask: Task<Void, Never>?

    private init() {
        all = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Drafts.shared.save() }
        }
    }

    func text(_ id: String) -> String { all[id] ?? "" }

    /// Something worth keeping is typed there (the sidebar keeps that chat listed).
    func has(_ id: String) -> Bool { !(all[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func set(_ id: String, _ text: String) {
        guard all[id] ?? "" != text else { return }
        let had = has(id)
        all[id] = text.isEmpty ? nil : text
        // Only redraw watchers (the sidebar) when a chat gains or loses its draft, not on every key.
        if had != has(id) { objectWillChange.send() }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { save() }
        }
    }

    func save() { UserDefaults.standard.set(all, forKey: Self.key) }
}
