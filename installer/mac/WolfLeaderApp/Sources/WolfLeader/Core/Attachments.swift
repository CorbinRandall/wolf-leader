import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Files and images added to a message: dropped on the chat box, pasted, or picked with the
/// paperclip. Images go to the agent as real images where it supports them; everything else is
/// passed as a file path the agent can open.
enum Attachments {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    /// Claude's per-image limit; bigger images go by path instead.
    static let inlineLimit = 5 * 1024 * 1024

    static func isImage(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }

    /// Where pasted or dragged-in image data is saved so the agent can read it.
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("WolfLeader/attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Saves image data (a screenshot on the clipboard, an image dragged from a browser) as a PNG.
    static func stash(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("image-\(stamp)-\(UUID().uuidString.prefix(4)).png")
        do { try png.write(to: url); return url } catch { return nil }
    }

    static func mimeType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    /// Base64 data for an image small enough to send inline, or nil.
    static func inlineData(_ url: URL) -> String? {
        guard isImage(url), let data = try? Data(contentsOf: url), data.count <= inlineLimit else { return nil }
        return data.base64EncodedString()
    }

    /// The lines added to a message for files the agent should open itself.
    static func note(for urls: [URL]) -> String? {
        guard !urls.isEmpty else { return nil }
        return "Attached files:\n" + urls.map { "- \($0.path)" }.joined(separator: "\n")
    }

    /// How a sent message shows attachments in the transcript.
    static func label(for urls: [URL]) -> String {
        urls.map { "📎 \($0.lastPathComponent)" }.joined(separator: "  ")
    }

    /// Reads file URLs and images off a drop or the pasteboard.
    static func load(_ providers: [NSItemProvider], into add: @escaping @MainActor ([URL]) -> Void) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in add([url]) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    Task { @MainActor in if let url = stash(image) { add([url]) } }
                }
            }
        }
    }

    /// Opens a file picker.
    @MainActor static func pick() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Add files or images to your message"
        return panel.runModal() == .OK ? panel.urls : []
    }
}

/// Small chips above the chat box, one per attachment, each with a remove button.
struct AttachmentTray: View {
    @Environment(\.palette) private var p
    @Binding var files: [URL]

    var body: some View {
        if !files.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(files, id: \.self) { url in
                        HStack(spacing: 6) {
                            if Attachments.isImage(url), let image = NSImage(contentsOf: url) {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 26, height: 26).clipShape(RoundedRectangle(cornerRadius: 5))
                            } else {
                                Image(systemName: "doc").foregroundStyle(p.textMuted)
                            }
                            Text(url.lastPathComponent).font(DS.Font.micro).foregroundStyle(p.text).lineLimit(1)
                                .frame(maxWidth: 140)
                            Button { files.removeAll { $0 == url } } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(p.textMuted)
                            }
                            .buttonStyle(.plain)
                            .help("Remove")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(p.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(p.border, lineWidth: 0.5))
                    }
                }
            }
        }
    }
}

/// The paperclip button.
struct AttachButton: View {
    @Environment(\.palette) private var p
    @Binding var files: [URL]

    var body: some View {
        Button { add(Attachments.pick()) } label: {
            Image(systemName: "paperclip").foregroundStyle(p.textMuted)
        }
        .buttonStyle(.plain)
        .help("Attach files or images (or drag them in)")
    }

    private func add(_ urls: [URL]) {
        for url in urls where !files.contains(url) { files.append(url) }
    }
}

extension View {
    /// Shift+Return adds a new line at the cursor instead of sending.
    func shiftReturnNewline() -> some View {
        onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.shift) || press.modifiers.contains(.option) else { return .ignored }
            NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
            return .handled
        }
    }

    /// Lets files and images be dropped or pasted into a chat box.
    func acceptsAttachments(_ files: Binding<[URL]>) -> some View {
        modifier(AttachmentDrop(files: files))
    }
}

private struct AttachmentDrop: ViewModifier {
    @Environment(\.palette) private var p
    @Binding var files: [URL]
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if hovering {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(p.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL, .image], isTargeted: $hovering) { providers in
                Attachments.load(providers) { add($0) }
                return true
            }
            .onPasteCommand(of: [.fileURL, .image]) { providers in
                Attachments.load(providers) { add($0) }
            }
    }

    private func add(_ urls: [URL]) {
        for url in urls where !files.contains(url) { files.append(url) }
    }
}
