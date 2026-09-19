import XCTest
@testable import DynamicIsland

final class IslandFileTrayAnimationTests: XCTestCase {
    func testLockAndFileTransitionsStayBrief() {
        XCTAssertGreaterThanOrEqual(IslandFileTrayAnimation.lockDuration, 0.15)
        XCTAssertLessThanOrEqual(IslandFileTrayAnimation.lockDuration, 0.3)
        XCTAssertGreaterThanOrEqual(IslandFileTrayAnimation.fileFadeDuration, 0.18)
        XCTAssertLessThanOrEqual(IslandFileTrayAnimation.fileFadeDuration, 0.3)
    }

    func testDeleteFeedbackRemainsVisibleThroughFileFade() {
        let impactDuration = Double(IslandFileTrayAnimation.impactHoldNanoseconds) / 1_000_000_000
        XCTAssertGreaterThanOrEqual(impactDuration, IslandFileTrayAnimation.fileFadeDuration)
        XCTAssertLessThan(impactDuration, 0.4)
    }
}
