import XCTest
@testable import DynamicIsland

final class IslandVisualStyleTests: XCTestCase {
    func testExpandedShellCloselyFramesMusicContent() {
        let shell = IslandVisualStyle.expandedShellSize(
            for: .music, timerMode: .stopwatch, hasTrayItems: false,
            hasError: false, hasTimerCompletion: false
        )
        let content = IslandVisualStyle.expandedContentSize
        let padding = IslandVisualStyle.expandedContentPadding
        let horizontalInset = (shell.width - content.width) / 2 + padding
        let availableMusicSurfaceHeight = shell.height
            - 2 * padding
            - IslandVisualStyle.expandedSurfaceSwitcherHeight
            - IslandVisualStyle.expandedSurfaceSpacing
        // Two metadata lines, progress track and labels, playback controls,
        // volume controls, and the three 4pt gaps in the right-hand VStack.
        let requiredMusicSurfaceHeight: CGFloat = 33 + 32 + 28 + 28 + 3 * 4

        XCTAssertEqual(shell.height, content.height)
        XCTAssertEqual(shell.height, IslandVisualStyle.expandedMusicHeight)
        XCTAssertGreaterThanOrEqual(
            availableMusicSurfaceHeight,
            requiredMusicSurfaceHeight,
            "Music controls must fit above the bottom content clip without flattening the volume buttons."
        )
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
        XCTAssertEqual(pomodoro.height, IslandVisualStyle.expandedTimerHeight)
        XCTAssertEqual(countdown.height, IslandVisualStyle.expandedTimerHeight)
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

        XCTAssertEqual(trayWithError.height, IslandVisualStyle.expandedTimerHeight)
        XCTAssertEqual(completedStopwatch.height, IslandVisualStyle.expandedTimerHeight)
    }

    func testExpandedCanvasContainsEverySurfaceShell() {
        let sizes = [IslandExpandedSurface.music, .fileTray, .tools].flatMap { surface in
            IslandTimerToolMode.allCases.map { mode in
                IslandVisualStyle.expandedShellSize(
                    for: surface,
                    timerMode: mode,
                    hasTrayItems: true,
                    hasError: false,
                    hasTimerCompletion: false
                )
            }
        }

        XCTAssertEqual(sizes.map(\.height).max(), IslandVisualStyle.expandedShellSize.height)
        XCTAssertEqual(IslandVisualStyle.expandedContentSize.height, IslandVisualStyle.expandedShellSize.height)
        XCTAssertTrue(sizes.allSatisfy { $0.width <= IslandVisualStyle.expandedContentSize.width + 12 })
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
        let musicSize = IslandVisualStyle.compactShellSize(baseSize: baseSize, hasCompactActivity: true)
        let timerSize = IslandVisualStyle.compactShellSize(
            baseSize: baseSize,
            hasCompactActivity: true,
            hasActiveTimer: true
        )

        XCTAssertEqual(timerSize.height, baseSize.height)
        XCTAssertEqual(
            timerSize.width,
            baseSize.width + IslandVisualStyle.timerCompactHorizontalExpansion
        )
        XCTAssertGreaterThan(timerSize.width, musicSize.width)
    }

    func testActivityCompactShellExpandsHorizontallyOnly() {
        let baseSize = CGSize(width: 216, height: 38)
        let idleSize = IslandVisualStyle.compactShellSize(baseSize: baseSize, hasCompactActivity: false)
        let activitySize = IslandVisualStyle.compactShellSize(baseSize: baseSize, hasCompactActivity: true)

        XCTAssertEqual(idleSize, baseSize)
        XCTAssertEqual(activitySize.height, baseSize.height)
        XCTAssertEqual(
            activitySize.width,
            baseSize.width + IslandVisualStyle.activityCompactHorizontalExpansion
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
