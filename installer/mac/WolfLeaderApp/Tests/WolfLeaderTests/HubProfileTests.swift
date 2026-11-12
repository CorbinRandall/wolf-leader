import XCTest
@testable import WolfLeader

final class HubProfileTests: XCTestCase {
    func testLegacySettingsDecodeWithoutProfiles() throws {
        let encoded = try JSONEncoder().encode(WolfConfig())
        let config = try JSONDecoder().decode(WolfConfig.self, from: encoded)
        XCTAssertNil(config.hubProfiles)
        XCTAssertNil(config.activeHubProfileID)
    }

    func testProfileIsolationAndLegacyFolders() throws {
        let base = URL(fileURLWithPath: "/tmp/wolf-test")
        let old = HubProfile(name: "Existing", hubURL: "http://wolf.local:6971", mcpURL: "http://wolf.local:6972/mcp", sshHost: "wolf")
        var other = old
        other.id = UUID().uuidString
        other.storageID = UUID().uuidString
        XCTAssertEqual(old.workspaceDirectory(base: base), base)
        XCTAssertNotEqual(other.workspaceDirectory(base: base), base)
        XCTAssertEqual(try JSONDecoder().decode(HubProfile.self, from: JSONEncoder().encode(other)), other)
        other.storageID = "../../outside"
        XCTAssertEqual(other.workspaceDirectory(base: base), base)
    }
}
