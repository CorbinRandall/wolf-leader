import AppKit
import SwiftUI

/// Where the app is: the sidebar section, and inside Projects, which view and which project.
struct Route: Hashable {
    var section: MainSection = .chats
    var projectsTab: String = "focus"
    var libraryTab: String = "skills"
    var projectID: Int?
    /// The open chat (in the Chats section, whatever project it belongs to).
    var chatID: String?
    /// Chats section without a chat open: the list of every chat instead of the new-chat page.
    var chatList = false
}

/// "Start a new chat", optionally already pointed at a project.
struct NewChatRequest: Equatable {
    let id = UUID()
    var project: ProjectRef?
    /// Open with "New project" picked, its name field ready.
    var newProject = false
}

/// One history for the whole window, like a browser: every section change, every switch between
/// Focus / Board / All, and every project opened is a step you can go back from and forward to.
@MainActor
final class Navigator: ObservableObject {
    @Published private(set) var route: Route
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// A search typed in the toolbar, waiting for Super Search to run it.
    @Published var pendingSearch: String?
    /// A Settings tab to show next (set by `open(settingsTab:)`).
    @Published var pendingSettingsTab: String?
    /// A new chat asked for from somewhere else (a project's + button); the new-chat page picks it up.
    @Published var pendingNewChat: NewChatRequest?

    private var backStack: [Route] = []
    private var forwardStack: [Route] = []
    private static let tabKey = "wl.projects.tab"

    init() {
        route = Route(projectsTab: UserDefaults.standard.string(forKey: Self.tabKey) ?? "focus")
    }

    func go(_ next: Route) {
        guard next != route else { return }
        backStack.append(route)
        if backStack.count > 200 { backStack.removeFirst() }
        forwardStack.removeAll()
        show(next)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(route)
        show(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(route)
        show(next)
    }

    private func show(_ next: Route) {
        route = next
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
        UserDefaults.standard.set(next.projectsTab, forKey: Self.tabKey)
    }

    // MARK: Steps

    /// Switch sidebar section. Coming back to Projects lands on the view you left, with no project open.
    func open(section: MainSection) {
        var next = route
        next.section = section
        next.projectID = nil
        next.chatID = nil
        next.chatList = false
        go(next)
    }

    /// The new-chat page, with this project already picked (nil: no project).
    func newChat(project: ProjectRef? = nil, newProject: Bool = false) {
        pendingNewChat = NewChatRequest(project: project, newProject: newProject)
        var next = route
        next.section = .chats
        next.projectID = nil
        next.chatID = nil
        next.chatList = false
        go(next)
    }

    /// Every chat, grouped by project, plus chats from other AI tools to bring in.
    func openChatList() {
        var next = route
        next.section = .chats
        next.projectID = nil
        next.chatID = nil
        next.chatList = true
        go(next)
    }

    /// Settings on a given tab ("agents", "updates", ...). SettingsView picks it up and clears it.
    func open(settingsTab: String) {
        pendingSettingsTab = settingsTab
        open(section: .settings)
    }

    func open(projectsTab: String) {
        var next = route
        next.section = .projects
        next.projectsTab = projectsTab
        next.projectID = nil
        next.chatID = nil
        go(next)
    }

    func open(libraryTab: String) {
        var next = route
        next.section = .library
        next.libraryTab = libraryTab
        next.projectID = nil
        next.chatID = nil
        go(next)
    }

    func open(project id: Int?) {
        var next = route
        next.section = .projects
        next.projectID = id
        next.chatID = nil
        go(next)
    }

    /// Open a chat. Every chat opens in the Chats section, so the sidebar shows it selected.
    func open(chat id: String, project: Int? = nil) {
        var next = route
        next.section = .chats
        next.projectID = nil
        next.chatID = id
        next.chatList = false
        go(next)
    }

    /// Leave a chat for the page it was opened from. If you came from there, that is simply "back".
    func closeChat() {
        if let previous = backStack.last, previous.chatID == nil {
            goBack()
        } else {
            newChat()
        }
    }

    func openSettingsSidebar() {
        open(section: .settings)
        open(settingsTab: "sidebar")
    }

    /// Run a search from anywhere: open the results page with this text.
    func search(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        pendingSearch = q
        open(section: .ask)
    }

    /// Leave a project page. If you came from the list, that is simply "back".
    func closeProject() {
        if let previous = backStack.last, previous.section == .projects, previous.projectID == nil {
            goBack()
        } else {
            open(project: nil)
        }
    }

    // MARK: Two-finger swipe, as in Safari and Chrome

    private var swipeMonitor: Any?

    func watchSwipes() {
        guard swipeMonitor == nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleSwipe(event)
            return event
        }
    }

    private var swipeTravel: CGFloat = 0
    private var swipeDrift: CGFloat = 0
    private var swipeFired = false

    /// Add up how far two fingers travel sideways in one gesture. Far enough, and mostly sideways,
    /// is back or forward. (The first event of a gesture carries no distance, so this cannot be
    /// decided there, and it should not depend on the Mac's "swipe between pages" setting.)
    private func handleSwipe(_ event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            swipeTravel = 0; swipeDrift = 0; swipeFired = false
        }
        guard event.phase.contains(.changed), !swipeFired else { return }
        // The board scrolls sideways itself; do not fight it.
        if route.section == .projects, route.projectID == nil, route.projectsTab == "board" { return }
        // Sheets (a session being read, an editor) keep their own gestures.
        if event.window?.sheets.isEmpty == false || event.window?.isSheet == true { return }
        // Fingers moving right is "back", whichever way the Mac's scroll direction is set.
        swipeTravel += event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        swipeDrift += abs(event.scrollingDeltaY)
        guard abs(swipeTravel) > 90, abs(swipeTravel) > swipeDrift * 3 else { return }
        swipeFired = true
        if swipeTravel > 0 { goBack() } else { goForward() }
    }
}
