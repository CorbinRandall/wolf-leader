import AppKit
import ScreenCaptureKit
import SwiftUI

/// Share your screen with whichever AI you're talking to: a picture of the screen goes along
/// with your message. Wolf Leader's own windows are left out, so the AI sees what you're
/// working on, not the chat.
@MainActor
final class ScreenShare: ObservableObject {
    static let shared = ScreenShare()

    /// A fresh picture of the screen goes with every message. Off again each time the app opens.
    @Published var everyMessage = false
    @Published var error: String?
    @Published private(set) var capturing = false
    /// The screen last chosen; "every message" keeps using it.
    private var chosen: CGDirectDisplayID?

    struct Screen: Identifiable, Hashable {
        var id: CGDirectDisplayID
        var name: String
    }

    var screens: [Screen] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return Screen(id: id, name: screen.localizedName)
        }
    }

    /// Take a picture of a screen now. Returns the saved image, or nil (and says why in `error`).
    func capture(_ display: CGDirectDisplayID? = nil) async -> URL? {
        if let display { chosen = display }
        capturing = true
        defer { capturing = false }
        do {
            let url = try await Self.snapshot(display: chosen ?? CGMainDisplayID(), folder: Attachments.folder)
            error = nil
            return url
        } catch {
            self.error = "Wolf Leader isn't allowed to see the screen yet. Turn it on in System Settings > Privacy & Security > Screen & System Audio Recording, then reopen Wolf Leader."
            everyMessage = false
            return nil
        }
    }

    /// The attachments for a message, with the screen added when "every message" is on.
    func adding(to files: [URL]) async -> [URL] {
        guard everyMessage, let shot = await capture() else { return files }
        return files + [shot]
    }

    private enum CaptureError: Error { case noDisplay, noImage }

    private nonisolated static func snapshot(display wanted: CGDirectDisplayID, folder: URL) async throws -> URL {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == wanted }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let config = SCStreamConfiguration()
        // Full sharpness up to 2560 across: plenty to read text, small enough to send.
        let pixels = CGFloat(display.width) * CGFloat(filter.pointPixelScale)
        let shrink = min(1, 2560 / max(pixels, 1))
        config.width = Int(pixels * shrink)
        config.height = Int(CGFloat(display.height) * CGFloat(filter.pointPixelScale) * shrink)
        config.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw CaptureError.noImage
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("screen-\(stamp)-\(UUID().uuidString.prefix(4)).jpg")
        try jpeg.write(to: url)
        return url
    }
}

/// The screen button next to a message box: add a picture of a screen now, or with every message.
struct ScreenButton: View {
    @Environment(\.palette) private var p
    @ObservedObject private var share = ScreenShare.shared
    @Binding var files: [URL]

    var body: some View {
        Menu {
            ForEach(share.screens) { screen in
                Button(share.screens.count > 1 ? "Add a picture of \(screen.name)" : "Add a picture of my screen") {
                    Task { if let url = await share.capture(screen.id) { files.append(url) } }
                }
            }
            Divider()
            Toggle("Share my screen with every message", isOn: $share.everyMessage)
        } label: {
            Image(systemName: share.everyMessage ? "rectangle.inset.filled.badge.record" : "macwindow.on.rectangle")
                .foregroundStyle(share.everyMessage ? p.bad : p.textMuted)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(share.everyMessage ? "Your screen goes with every message. Click to change."
              : "Show the AI your screen (Wolf Leader's own window is left out)")
        .popover(isPresented: Binding(get: { share.error != nil }, set: { if !$0 { share.error = nil } })) {
            Text(share.error ?? "").font(DS.Font.caption).padding(12).frame(maxWidth: 300)
        }
    }
}
