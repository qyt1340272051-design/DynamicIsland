import XCTest
@testable import DynamicIsland

final class IslandPlaybackProgressAppearanceTests: XCTestCase {
    func testDotOnlyAppearsForSeekableHoveredOrDraggedProgress() {
        XCTAssertFalse(IslandPlaybackProgressAppearance.showsDot(canSeek: true, hovered: false, dragging: false))
        XCTAssertTrue(IslandPlaybackProgressAppearance.showsDot(canSeek: true, hovered: true, dragging: false))
        XCTAssertTrue(IslandPlaybackProgressAppearance.showsDot(canSeek: true, hovered: false, dragging: true))
        XCTAssertFalse(IslandPlaybackProgressAppearance.showsDot(canSeek: false, hovered: true, dragging: true))
    }

    func testDotTracksProgressAndRemainsInsideBothEnds() {
        XCTAssertEqual(IslandPlaybackProgressAppearance.dotOffset(progress: 0, width: 100), 0)
        XCTAssertEqual(IslandPlaybackProgressAppearance.dotOffset(progress: 0.5, width: 100), 45)
        XCTAssertEqual(IslandPlaybackProgressAppearance.dotOffset(progress: 1, width: 100), 90)
        XCTAssertEqual(IslandPlaybackProgressAppearance.dotOffset(progress: -1, width: 100), 0)
        XCTAssertEqual(IslandPlaybackProgressAppearance.dotOffset(progress: 2, width: 100), 90)
    }
}
