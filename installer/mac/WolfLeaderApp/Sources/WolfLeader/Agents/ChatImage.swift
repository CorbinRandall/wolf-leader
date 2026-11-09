import AppKit

/// Embedded in the saved chat so attachments survive a restart and device sync.
struct ChatImage: Identifiable, Codable, Hashable {
    var id = UUID().uuidString
    var data: Data

    init(_ image: NSImage) throws {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]),
              png.count <= 5 * 1024 * 1024 else {
            throw AgentError.failed("Choose an image smaller than 5 MB.")
        }
        data = png
    }
}
