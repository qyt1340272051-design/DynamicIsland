import XCTest
@testable import DynamicIsland

final class IslandVisualStyleTests: XCTestCase {
    func testExpandedShellCloselyFramesMusicContent() {
        let shell = IslandVisualStyle.expandedShellSize
        let content = IslandVisualStyle.expandedContentSize
        let padding = IslandVisualStyle.expandedContentPadding
        let horizontalInset = (shell.width - content.width) / 2 + padding

        XCTAssertEqual(shell.height, content.height)
        XCTAssertGreaterThanOrEqual(content.height - 2 * padding, 28 + 8 + 124)
        XCTAssertGreaterThanOrEqual(horizontalInset, 16)
        XCTAssertLessThanOrEqual(horizontalInset, 24)
        XCTAssertLessThan(shell.height, IslandPanelGeometry.expandedSize.height)
    }

    func testShorterSurfacesUseTighterExpandedShell() {
        let emptyTray = IslandVisualStyle.expandedShellSize(
            for: .fileTray, timerMode: .stopwatch, hasTrayItems: false,
            hasError: false, hasTimerCompletion: false
        )
        let filledTray = IslandVisualStyle.expandedShellSize(
            for: .fileTray, timerMode: .stopwatch, hasTrayItems: true,
            hasError: false, hasTimerCompletion: false
        )
        let stopwatch = IslandVisualStyle.expandedShellSize(
            for: .tools, timerMode: .stopwatch, hasTrayItems: false,
            hasError: false, hasTimerCompletion: false
        )
        let pomodoro = IslandVisualStyle.expandedShellSize(
            for: .tools, timerMode: .pomodoro, hasTrayItems: false,
            hasError: false, hasTimerCompletion: false
        )
        let countdown = IslandVisualStyle.expandedShellSize(
            for: .tools, timerMode: .countdown, hasTrayItems: false,
            hasError: false, hasTimerCompletion: false
        )

        XCTAssertEqual(emptyTray.height, IslandVisualStyle.expandedCompactContentHeight)
        XCTAssertEqual(filledTray.height, IslandVisualStyle.expandedFileTrayHeight)
        XCTAssertEqual(stopwatch.height, IslandVisualStyle.expandedCompactContentHeight)
        XCTAssertEqual(pomodoro, IslandVisualStyle.expandedShellSize)
        XCTAssertEqual(countdown, IslandVisualStyle.expandedShellSize)
    }

    func testMessagesAndTimerCompletionKeepEnoughHeight() {
        let trayWithError = IslandVisualStyle.expandedShellSize(
            for: .fileTray, timerMode: .stopwatch, hasTrayItems: true,
            hasError: true, hasTimerCompletion: false
        )
        let completedStopwatch = IslandVisualStyle.expandedShellSize(
            for: .tools, timerMode: .stopwatch, hasTrayItems: false,
            hasError: false, hasTimerCompletion: true
        )

        XCTAssertEqual(trayWithError, IslandVisualStyle.expandedShellSize)
        XCTAssertEqual(completedStopwatch, IslandVisualStyle.expandedShellSize)
    }

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
        let radii = IslandVisualStyle.shellCornerRadii(isExpanded: true, shellHeight: 190)

        XCTAssertEqual(radii.top, 26)
        XCTAssertEqual(radii.bottom, 26)
    }
}
