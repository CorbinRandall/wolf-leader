import SwiftUI
import WebKit

/// Chats: talk to Claude Code, Codex and the other agents from inside Wolf Leader.
/// Every chat starts with the project's Wolf brief and is saved to the hub after each turn.
struct ChatsView: View {
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @ObservedObject private var engine = AgentEngine.shared

    var body: some View {
        ZStack {
            AgentWebView(webView: engine.webView)
                .opacity(engine.state == .ready ? 1 : 0)
            switch engine.state {
            case .ready:
                EmptyView()
            case .idle, .starting:
                VStack(spacing: DS.Spacing.md) {
                    ProgressView()
                    Text(statusText).font(DS.Font.bodySmall).foregroundStyle(p.textMuted)
                }
            case .failed(let message):
                VStack(spacing: DS.Spacing.md) {
                    Image(systemName: "exclamationmark.bubble").font(.system(size: 28)).foregroundStyle(p.bad)
                    Text(message)
                        .font(DS.Font.bodySmall)
                        .foregroundStyle(p.text)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 420)
                    Button("Try again") { Task { await engine.restart() } }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(DS.Spacing.lg)
            }
        }
        .task(id: store.config.hubURL) { await engine.open(hubURL: store.config.hubURL) }
    }

    private var statusText: String {
        if case .starting(let text) = engine.state { return text }
        return "Starting the agents…"
    }
}

/// Hosts the engine's single web view; SwiftUI may rebuild this wrapper, the view stays the same.
private struct AgentWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
