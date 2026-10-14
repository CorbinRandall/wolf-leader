import AppKit
import SwiftUI

/// Where the app is: the sidebar section, and inside Projects, which view and which project.
struct Route: Hashable {
    var section: MainSection = .projects
    var projectsTab: String = "focus"
    var libraryTab: String = "skills"
    var projectID: Int?
}

/// One history for the whole window, like a browser: every section change, every switch between
/// Focus / Board / All, and every project opened is a step you can go back from and forward to.
@MainActor
final class Navigator: ObservableObject {
    @Published private(set) var route: Route
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

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
        go(next)
    }

    func open(projectsTab: String) {
        var next = route
        next.section = .projects
        next.projectsTab = projectsTab
        next.projectID = nil
        go(next)
    }

    func open(libraryTab: String) {
        var next = route
        next.section = .library
        next.libraryTab = libraryTab
        next.projectID = nil
        go(next)
    }

    func open(project id: Int?) {
        var next = route
        next.section = .projects
        next.projectID = id
        go(next)
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

    private func handleSwipe(_ event: NSEvent) {
        // Only a deliberate sideways two-finger swipe, and only when the Mac's own setting allows it.
        guard event.phase == .began, NSEvent.isSwipeTrackingFromScrollEventsEnabled,
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 2 else { return }
        // The board scrolls sideways itself; do not fight it.
        if route.section == .projects, route.projectID == nil, route.projectsTab == "board" { return }
        // Sheets (a session being read, an editor) keep their own gestures.
        if event.window?.sheets.isEmpty == false || event.window?.isSheet == true { return }
        guard canGoBack || canGoForward else { return }
        event.trackSwipeEvent(options: [.lockDirection], dampenAmountThresholdMin: canGoForward ? -1 : 0,
                              max: canGoBack ? 1 : 0) { [weak self] amount, phase, complete, _ in
            guard phase == .ended, complete else { return }
            Task { @MainActor in
                if amount > 0 { self?.goBack() } else if amount < 0 { self?.goForward() }
            }
        }
    }
}
