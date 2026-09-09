import XCTest
@testable import DynamicIsland

final class IslandCompactPlaybackAnimationTests: XCTestCase {
    func testIndicatorUsesSixDots() {
        XCTAssertEqual(IslandCompactPlaybackAnimation.dotCount, 6)
        XCTAssertEqual(IslandCompactPlaybackAnimation.indicatorWidth, 28)
    }

    func testDotHeightsStayWithinVisibleRange() {
        for tick in 0..<40 {
            for index in 0..<IslandCompactPlaybackAnimation.dotCount {
                let height = IslandCompactPlaybackAnimation.height(
                    for: index,
                    at: Double(tick) / 20
                )
                XCTAssertGreaterThanOrEqual(height, IslandCompactPlaybackAnimation.minimumHeight)
                XCTAssertLessThanOrEqual(height, IslandCompactPlaybackAnimation.maximumHeight)
            }
        }
    }

    func testDotsChangeAtDifferentRates() {
        let heights = (0..<IslandCompactPlaybackAnimation.dotCount).map {
            IslandCompactPlaybackAnimation.height(for: $0, at: 0.37)
        }
        let distinctHeights = Set(heights.map { Int(($0 * 100).rounded()) })

        XCTAssertGreaterThanOrEqual(distinctHeights.count, 4)
        XCTAssertNotEqual(
            IslandCompactPlaybackAnimation.height(for: 0, at: 0),
            IslandCompactPlaybackAnimation.height(for: 0, at: 0.31),
            accuracy: 0.1
        )
    }
}
