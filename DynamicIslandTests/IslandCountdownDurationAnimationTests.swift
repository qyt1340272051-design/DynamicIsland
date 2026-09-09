import XCTest
@testable import DynamicIsland

final class IslandCountdownDurationAnimationTests: XCTestCase {
    func testCountdownAdjustmentAnimationIsSmoothAndResponsive() {
        XCTAssertGreaterThanOrEqual(IslandCountdownDurationAnimation.duration, 0.16)
        XCTAssertLessThanOrEqual(IslandCountdownDurationAnimation.duration, 0.28)
    }
}
