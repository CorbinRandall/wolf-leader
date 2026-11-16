import AppKit
import SwiftUI

/// A chat text box that grows with what you type, up to `maxHeight`, then scrolls (with a
/// scroll bar). Return sends; Shift- or Option-Return adds a new line. Very large pastes are cut
/// to `limit` characters so they can't freeze the app.
struct GrowingComposer: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont = .systemFont(ofSize: 13)
    var minHeight: CGFloat = 22
    var maxHeight: CGFloat
    var limit = 20_000
    var focused = false
    var disabled = false
    var onSubmit: () -> Void
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = OverlayScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // Overlay scroll bar: it floats over the text, so showing it never changes the width
        // (which used to re-wrap the text and make the box flicker on every key).
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder

        let view = ComposerTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = font
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.placeholder = placeholder
        view.limit = limit
        view.onSubmit = { context.coordinator.parent.onSubmit() }
        view.string = text
        scroll.documentView = view
        context.coordinator.view = view
        DispatchQueue.main.async { context.coordinator.measure() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = context.coordinator.view else { return }
        if view.string != text {
            view.string = text
            context.coordinator.measure()
        }
        view.placeholder = placeholder
        view.isEditable = !disabled
        view.onSubmit = { context.coordinator.parent.onSubmit() }
        if focused, !context.coordinator.didFocus, let window = view.window {
            context.coordinator.didFocus = true
            window.makeFirstResponder(view)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingComposer
        weak var view: ComposerTextView?
        var didFocus = false

        init(_ parent: GrowingComposer) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            parent.text = view.string
            measure()
        }

        /// Size the box to its text, clamped between the min and max heights.
        func measure() {
            guard let view, let container = view.textContainer, let layout = view.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + view.textContainerInset.height * 2
            let next = min(max(used, parent.minHeight), parent.maxHeight)
            if abs(next - parent.height) > 1 {
                DispatchQueue.main.async { self.parent.height = next }
            }
            view.scrollRangeToVisible(view.selectedRange())
        }
    }
}

/// Keeps the floating scroll bar even when macOS prefers always-visible ones (e.g. a mouse is plugged in).
final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}

final class ComposerTextView: NSTextView {
    var onSubmit: () -> Void = {}
    var limit = 20_000
    var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if isReturn && !hasMarkedText() {
            if mods.contains(.shift) || mods.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
            } else if mods.isEmpty {
                onSubmit()
            } else {
                super.keyDown(with: event)
            }
            return
        }
        super.keyDown(with: event)
    }

    /// Cut huge pastes down instead of letting them lock up the app.
    override func paste(_ sender: Any?) {
        guard let pasted = NSPasteboard.general.string(forType: .string) else { return super.paste(sender) }
        let room = max(0, limit - (string as NSString).length + selectedRange().length)
        insertText(String(pasted.prefix(room)), replacementRange: selectedRange())
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 13),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        NSString(string: placeholder).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attrs)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
