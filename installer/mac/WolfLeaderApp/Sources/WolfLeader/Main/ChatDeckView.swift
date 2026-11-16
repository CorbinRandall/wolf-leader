import SwiftUI

/// The deck: open chats side by side, one column each, scrollable horizontally.
/// Opening a new chat adds a column to the right. Closing one removes it.
struct ChatDeckView: View {
    @EnvironmentObject private var nav: Navigator
    @EnvironmentObject private var store: ConfigStore
    @Environment(\.palette) private var p
    @ObservedObject private var chats = ChatStore.shared
    var projectsModel: ProjectsModel

    private let minColWidth: CGFloat = 420

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(nav.openChatIDs, id: \.self) { id in
                            column(id: id, geo: geo)
                                .id(id)
                        }
                        addButton
                    }
                    .frame(minHeight: geo.size.height)
                }
                .onChange(of: nav.openChatIDs) { old, new in
                    guard let last = new.last, !old.contains(last) else { return }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last, anchor: .trailing) }
                }
            }
        }
    }

    @ViewBuilder
    private func column(id: String, geo: GeometryProxy) -> some View {
        if let session = chats.session(id) {
            HStack(spacing: 0) {
                if nav.openChatIDs.first != id {
                    Rectangle().fill(p.border).frame(width: 1)
                }
                ChatView(session: session, back: { nav.close(chatID: id) })
                    .frame(width: columnWidth(total: geo.size.width))
            }
        }
    }

    private func columnWidth(total: CGFloat) -> CGFloat {
        let count = CGFloat(nav.openChatIDs.count)
        return max(minColWidth, total / min(count, 3))
    }

    private var addButton: some View {
        Button {
            nav.showingNewChatPanel = true
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus.bubble")
                    .font(.system(size: 17))
                Text("New chat")
                    .font(DS.Font.micro)
            }
            .foregroundStyle(p.textMuted)
            .frame(width: 72)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New chat (⌘N)")
    }
}
