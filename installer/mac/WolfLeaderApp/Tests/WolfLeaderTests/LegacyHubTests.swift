import XCTest
@testable import WolfLeader

final class LegacyHubTests: XCTestCase {
    @MainActor func testOriginalHubProjectsWhenConfigured() async throws {
        guard let address = ProcessInfo.processInfo.environment["WOLF_TEST_HUB_URL"] else {
            throw XCTSkip("Set WOLF_TEST_HUB_URL to exercise a legacy hub without storing its address.")
        }
        let hub = HubClient(baseURL: address)
        let projects = try await hub.projects()
        XCTAssertFalse(projects.isEmpty)
        let columns = try await hub.kanbanColumns()
        XCTAssertTrue(columns.isEmpty)
        let model = ProjectsModel()
        await model.load(hub)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.entries.count, projects.count)
        XCTAssertNotNil(model.notice)
    }
}
