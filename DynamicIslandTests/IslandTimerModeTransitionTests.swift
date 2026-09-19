import XCTest
@testable import DynamicIsland

final class IslandTimerModeTransitionTests: XCTestCase {
    func testTimerModeCrossfadeIsSmoothAndResponsive() {
        XCTAssertGreaterThanOrEqual(IslandTimerModeTransition.duration, 0.18)
        XCTAssertLessThanOrEqual(IslandTimerModeTransition.duration, 0.3)
    }

    func testGrowingShellFinishesBeforeNewTimerContentFadesIn() {
        XCTAssertLessThan(
            IslandTimerModeTransition.shellDuration,
            IslandExpansionAnimation.shellDuration
        )
        XCTAssertLessThanOrEqual(
            IslandTimerModeTransition.shellDuration,
            IslandTimerModeTransition.incomingDelay
        )
        XCTAssertLessThanOrEqual(
            IslandTimerModeTransition.incomingDelay + IslandTimerModeTransition.incomingDuration,
            IslandTimerModeTransition.duration + 0.000_001
        )
    }

    func testTallTimerContentFadesOutBeforeShellShrinks() {
        XCTAssertLessThanOrEqual(
            IslandTimerModeTransition.outgoingDuration,
            IslandTimerModeTransition.shellShrinkDelay
        )
        XCTAssertLessThanOrEqual(
            IslandTimerModeTransition.shellShrinkDelay + IslandTimerModeTransition.shellDuration,
            IslandTimerModeTransition.duration
        )
    }
}
