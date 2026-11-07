import Foundation

final class Drafts: ObservableObject {
    static let shared = Drafts()

    private static let key = "wl.drafts"
    private var store: [String: String] = [:]

    private init() {
        store = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    subscript(chatID: String) -> String {
        get { store[chatID] ?? "" }
        set {
            if newValue.isEmpty {
                store.removeValue(forKey: chatID)
            } else {
                store[chatID] = newValue
            }
            UserDefaults.standard.set(store, forKey: Self.key)
            objectWillChange.send()
        }
    }
}
