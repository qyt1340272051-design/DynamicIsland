import XCTest
@testable import DynamicIsland

final class IslandTrackSkipAnimationTests: XCTestCase {
    func testPreviousAndNextTravelInOppositeDirections() {
        let distance = IslandTrackSkipAnimation.travelDistance

        XCTAssertLessThan(
            IslandTrackSkipAnimation.offset(for: .backward, distance: distance),
            0
        )
        XCTAssertGreaterThan(
            IslandTrackSkipAnimation.offset(for: .forward, distance: distance),
            0
        )
    }

    func testEachPassResetsFromTheOppositeSide() {
        let resetDistance = -IslandTrackSkipAnimation.resetDistance

        XCTAssertGreaterThan(
            IslandTrackSkipAnimation.offset(for: .backward, distance: resetDistance),
            0
        )
        XCTAssertLessThan(
            IslandTrackSkipAnimation.offset(for: .forward, distance: resetDistance),
            0
        )
    }

    func testSkipAnimationLoopsBrieflyAfterEachClick() {
        XCTAssertEqual(IslandTrackSkipAnimation.loopCount, 1)
        XCTAssertGreaterThan(IslandTrackSkipAnimation.totalDuration, 0.3)
        XCTAssertLessThan(IslandTrackSkipAnimation.totalDuration, 0.7)
    }
}
