import XCTest
import AppKit
@testable import WolfLeader

final class ChatImageTests: XCTestCase {
    func testImageRoundTripAndLegacyChat() throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.addRepresentation(bitmap)
        let attachment = try ChatImage(image)
        XCTAssertEqual(Array(attachment.data.prefix(4)), [137, 80, 78, 71])
        let item = ChatItem(id: "test", kind: .user, text: "Describe this", images: [attachment])
        let encoded = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(ChatItem.self, from: encoded), item)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "images")
        XCTAssertNil(try JSONDecoder().decode(ChatItem.self, from: JSONSerialization.data(withJSONObject: legacy)).images)
    }

    func testInvalidImageIsRejected() {
        XCTAssertThrowsError(try ChatImage(NSImage()))
    }
}
