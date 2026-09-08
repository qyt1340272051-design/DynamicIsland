import XCTest
@testable import DynamicIsland

final class IslandVisualStyleTests: XCTestCase {
    func testExpandedShellHasNoVisibleBorderOrShadow() {
        XCTAssertEqual(IslandVisualStyle.shellShadowOpacity(isCompactHovering: false), 0)
        XCTAssertEqual(IslandVisualStyle.expandedShellStrokeOpacity, 0)
    }

    func testCompactHoverShellShowsShadowOnlyWhilePointerHovering() {
        XCTAssertGreaterThan(IslandVisualStyle.shellShadowOpacity(isCompactHovering: true), 0)
        XCTAssertEqual(IslandVisualStyle.shellShadowOpacity(isCompactHovering: false), 0)
    }

    func testDraggingCanStillShowDropTargetBorder() {
        XCTAssertGreaterThan(IslandVisualStyle.draggingShellStrokeOpacity, 0)
    }

    func testCompactPlaybackContentIsVisibleOnlyWhilePlayingAndCollapsed() {
        XCTAssertEqual(IslandVisualStyle.compactContentOpacity(isExpanded: false, hasCompactContent: true), 1)
        XCTAssertEqual(IslandVisualStyle.compactContentOpacity(isExpanded: false, hasCompactContent: false), 0)
        XCTAssertEqual(IslandVisualStyle.compactContentOpacity(isExpanded: true, hasCompactContent: true), 0)
    }

    func testActiveTimerUsesWiderCompactPresentationThanMusic() {
        let baseSize = CGSize(width: 216, height: 38)
        let musicSize = IslandVisualStyle.compactShellSize(baseSize: baseSize, isPlaying: true)
        let timerSize = IslandVisualStyle.compactShellSize(
            baseSize: baseSize,
            isPlaying: true,
            hasActiveTimer: true
        )

        XCTAssertEqual(timerSize.height, baseSize.height)
        XCTAssertEqual(
            timerSize.width,
            baseSize.width + IslandVisualStyle.timerCompactHorizontalExpansion
        )
        XCTAssertGreaterThan(timerSize.width, musicSize.width)
    }

    func testPlayingCompactShellExpandsHorizontallyOnly() {
        let baseSize = CGSize(width: 216, height: 38)
        let pausedSize = IslandVisualStyle.compactShellSize(baseSize: baseSize, isPlaying: false)
        let playingSize = IslandVisualStyle.compactShellSize(baseSize: baseSize, isPlaying: true)

        XCTAssertEqual(pausedSize, baseSize)
        XCTAssertEqual(playingSize.height, baseSize.height)
        XCTAssertEqual(
            playingSize.width,
            baseSize.width + IslandVisualStyle.playingCompactHorizontalExpansion
        )
    }

    func testCompactShellUsesStraightTopAndRoundedBottomCorners() {
        let radii = IslandVisualStyle.shellCornerRadii(isExpanded: false, shellHeight: 38)

        XCTAssertEqual(radii.top, 0)
        XCTAssertEqual(radii.bottom, 19)
    }

    func testExpandedShellKeepsSymmetricRoundedCorners() {
        let radii = IslandVisualStyle.shellCornerRadii(isExpanded: true, shellHeight: 220)

        XCTAssertEqual(radii.top, 30)
        XCTAssertEqual(radii.bottom, 30)
    }
}
