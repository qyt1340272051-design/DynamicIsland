import XCTest
@testable import DynamicIsland

final class IslandPomodoroPresetAnimationTests: XCTestCase {
    func testPresetSelectionAnimationIsSmoothAndResponsive() {
        XCTAssertGreaterThanOrEqual(IslandPomodoroPresetAnimation.duration, 0.16)
        XCTAssertLessThanOrEqual(IslandPomodoroPresetAnimation.duration, 0.28)
    }
}
