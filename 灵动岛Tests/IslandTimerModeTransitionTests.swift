import XCTest
@testable import DynamicIsland

final class IslandTimerModeTransitionTests: XCTestCase {
    func testTimerModeCrossfadeIsSmoothAndResponsive() {
        XCTAssertGreaterThanOrEqual(IslandTimerModeTransition.duration, 0.18)
        XCTAssertLessThanOrEqual(IslandTimerModeTransition.duration, 0.3)
    }
}
