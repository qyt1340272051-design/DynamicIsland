import XCTest
@testable import DynamicIsland

final class IslandExpansionAnimationTests: XCTestCase {
    func testShellAnimationIsDeliberateAndSmooth() {
        XCTAssertGreaterThanOrEqual(IslandExpansionAnimation.shellDuration, 0.4)
        XCTAssertLessThanOrEqual(IslandExpansionAnimation.shellDuration, 0.8)
        XCTAssertGreaterThan(IslandExpansionAnimation.contentRevealDelay, 0)
        XCTAssertLessThan(IslandExpansionAnimation.contentRevealDelay, IslandExpansionAnimation.shellDuration)
    }

    func testShellExpansionIsSnappy() {
        XCTAssertLessThanOrEqual(IslandExpansionAnimation.shellDuration, 0.5)
        XCTAssertLessThanOrEqual(
            IslandExpansionAnimation.contentRevealDelay,
            IslandExpansionAnimation.shellDuration * 0.7
        )
    }

    func testExpandedContentRevealsEarlyAndFinishesBeforeShellSettles() {
        XCTAssertLessThanOrEqual(
            IslandExpansionAnimation.contentRevealDelay,
            IslandExpansionAnimation.shellDuration * 0.35
        )
        XCTAssertLessThan(
            IslandExpansionAnimation.contentRevealDelay + IslandExpansionAnimation.contentRevealDuration,
            IslandExpansionAnimation.shellDuration
        )
    }

    func testExpandedContentScalesOutwardFromCenter() {
        XCTAssertLessThan(IslandExpansionAnimation.compactContentScale, 1)
        XCTAssertGreaterThan(IslandExpansionAnimation.compactContentScale, 0.85)
        XCTAssertEqual(IslandExpansionAnimation.expandedContentScale, 1)
    }

    func testPointerHoverScaleIsSubtle() {
        XCTAssertGreaterThan(IslandExpansionAnimation.pointerHoverScale, 1)
        XCTAssertLessThanOrEqual(IslandExpansionAnimation.pointerHoverScale, 1.06)
    }
}
