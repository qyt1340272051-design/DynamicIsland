import XCTest
@testable import DynamicIsland

final class IslandSurfaceTransitionTests: XCTestCase {
    func testSurfaceCrossfadeIsVisibleWithoutFeelingSlow() {
        XCTAssertGreaterThanOrEqual(IslandSurfaceTransition.duration, 0.18)
        XCTAssertLessThanOrEqual(IslandSurfaceTransition.duration, 0.3)
    }
}
