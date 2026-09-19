import XCTest
@testable import DynamicIsland

final class IslandQuitAnimationTests: XCTestCase {
    func testImpactReboundsBeforeIslandFade() {
        let feedbackDuration = Double(
            IslandQuitAnimation.impactHoldNanoseconds + IslandQuitAnimation.reboundWaitNanoseconds
        ) / 1_000_000_000

        XCTAssertGreaterThan(feedbackDuration, 0.2)
        XCTAssertLessThan(feedbackDuration, 0.4)
        XCTAssertGreaterThan(IslandQuitAnimation.pressedScale, 0.7)
        XCTAssertLessThan(IslandQuitAnimation.pressedScale, 1)
    }

    func testQuitWaitsForWholeIslandFade() {
        let fadeWait = Double(IslandQuitAnimation.fadeWaitNanoseconds) / 1_000_000_000
        let totalDuration = Double(
            IslandQuitAnimation.impactHoldNanoseconds
                + IslandQuitAnimation.reboundWaitNanoseconds
                + IslandQuitAnimation.fadeWaitNanoseconds
        ) / 1_000_000_000

        XCTAssertGreaterThan(fadeWait, IslandQuitAnimation.fadeDuration)
        XCTAssertLessThan(totalDuration, 1)
    }
}
