import AppKit
import SwiftUI
import WebKit

/// The hub's wiki (`/wiki/`) inside the app: same pages, search and links as in a browser.
struct WikiView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @StateObject private var browser = WikiBrowser()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                WikiWebView(browser: browser)
                if let failure = browser.failure {
                    MainNotice(symbol: "book.closed", title: "Wiki unavailable", message: failure) {
                        Button("Try again") { browser.reload() }.buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(DS.Spacing.lg)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(p.background)
                }
            }
        }
        .background(p.background)
        .task(id: store.config.hubURL) { browser.open(home: store.config.wikiURL) }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            iconButton("chevron.left", "Back", enabled: browser.canGoBack) { browser.web.goBack() }
            iconButton("chevron.right", "Forward", enabled: browser.canGoForward) { browser.web.goForward() }
            iconButton("arrow.clockwise", "Reload") { browser.reload() }
            iconButton("house", "Wiki home") { browser.goHome() }
            Text(browser.title.isEmpty ? "Wiki" : browser.title)
                .font(DS.Font.bodySmall.weight(.semibold))
                .foregroundStyle(p.text)
                .lineLimit(1)
                .padding(.leading, 6)
            if browser.loading { ProgressView().controlSize(.small).padding(.leading, 4) }
            Spacer(minLength: 8)
            Button("Open in browser") { MainLinks.open(browser.web.url ?? store.config.wikiURL) }
                .buttonStyle(OutlineButtonStyle())
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, 8)
    }

    private func iconButton(_ symbol: String, _ label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? p.text : p.textMuted.opacity(0.5))
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Owns the web view so its page and history survive SwiftUI redraws.
@MainActor
final class WikiBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let web: WKWebView
    @Published var title = ""
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var failure: String?

    private var home: URL?
    private var watchers: [NSKeyValueObservation] = []

    override init() {
        web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.allowsMagnification = true
        watchers = [
            web.observe(\.title) { [weak self] view, _ in Task { @MainActor in self?.title = view.title ?? "" } },
            web.observe(\.isLoading) { [weak self] view, _ in Task { @MainActor in self?.loading = view.isLoading } },
            web.observe(\.canGoBack) { [weak self] view, _ in Task { @MainActor in self?.canGoBack = view.canGoBack } },
            web.observe(\.canGoForward) { [weak self] view, _ in Task { @MainActor in self?.canGoForward = view.canGoForward } },
        ]
    }

    /// Load the wiki's front page, unless this hub's wiki is already showing.
    func open(home: URL?) {
        guard let home else { failure = "The hub address isn't a valid URL."; return }
        if self.home == home, web.url != nil, failure == nil { return }
        self.home = home
        goHome()
    }

    func goHome() {
        guard let home else { return }
        failure = nil
        web.load(URLRequest(url: home))
    }

    func reload() {
        failure = nil
        if web.url == nil { goHome() } else { web.reload() }
    }

    private func isHubPage(_ url: URL) -> Bool {
        guard let home else { return false }
        return url.host == home.host && url.port == home.port
    }

    // Wiki and hub pages stay in the app; anything else opens in the default browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if scheme == "about" || scheme == "blob" || scheme == "data" { return .allow }
        if (scheme == "http" || scheme == "https"), isHubPage(url) { return .allow }
        if action.targetFrame?.isMainFrame == false { return .allow }
        NSWorkspace.shared.open(url)
        return .cancel
    }

    // Links that ask for a new window open in place (hub pages) or in the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if isHubPage(url) { webView.load(action.request) } else { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { failure = nil }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode == 404,
           http.url == home {
            failure = "This hub has not built its wiki yet. It is generated after the first save."
            return .cancel
        }
        return .allow
    }

    private func report(_ error: Error) {
        let code = (error as NSError).code
        // Cancelled loads (a new click, or a link handed to the browser) are not failures.
        if code == NSURLErrorCancelled || code == 102 { return }
        failure = "Can't load the wiki: \(error.localizedDescription)"
    }
}

private struct WikiWebView: NSViewRepresentable {
    let browser: WikiBrowser
    func makeNSView(context: Context) -> WKWebView { browser.web }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
