import CoreGraphics
import XCTest
@testable import DynamicIsland

final class IslandPanelHoverRegionTests: XCTestCase {
    func testExpandedFrameStillContainsPointerFromCompactFrame() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1728, height: 1071)
        let left = CGRect(x: 0, y: 1079, width: 756, height: 38)
        let right = CGRect(x: 972, y: 1079, width: 756, height: 38)
        let compact = IslandPanelGeometry.compactFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            auxiliaryTopLeftArea: left,
            auxiliaryTopRightArea: right
        )
        let expanded = IslandPanelGeometry.expandedFrame(
            screenFrame: screenFrame,
            auxiliaryTopLeftArea: left,
            auxiliaryTopRightArea: right,
            safeAreaInsetsTop: 38
        )

        XCTAssertTrue(IslandPanelHoverRegion.contains(CGPoint(x: compact.midX, y: compact.midY), in: expanded))
    }

    func testPointOutsideToleranceIsNotInsideHoverRegion() {
        let frame = CGRect(x: 100, y: 100, width: 260, height: 46)

        XCTAssertFalse(IslandPanelHoverRegion.contains(CGPoint(x: 90, y: frame.midY), in: frame))
    }

    func testHoverRegionGrowsWithPointerFeedback() {
        let frame = CGRect(x: 100, y: 100, width: 260, height: 46)

        let hoverFrame = IslandPanelHoverRegion.hoverFrame(for: frame, isPointerInside: true)

        XCTAssertGreaterThan(hoverFrame.width, frame.width)
        XCTAssertGreaterThan(hoverFrame.height, frame.height)
        XCTAssertTrue(IslandPanelHoverRegion.contains(CGPoint(x: frame.maxX + 4, y: frame.midY), in: hoverFrame))
        XCTAssertFalse(IslandPanelHoverRegion.contains(CGPoint(x: frame.maxX + 12, y: frame.midY), in: hoverFrame))
    }

    func testCompactPointerFeedbackCapsWidthAndKeepsScreenTop() {
        let compact = CGRect(x: 100, y: 900, width: 438, height: 32)
        let hover = IslandPanelHoverRegion.hoverFrame(for: compact, isPointerInside: true, maximumWidth: 440)
        XCTAssertEqual(hover.width, 440)
        XCTAssertEqual(hover.height, 32 * IslandExpansionAnimation.pointerHoverScale)
        XCTAssertEqual(hover.midX, compact.midX)
        XCTAssertEqual(hover.maxY, compact.maxY)
    }

    func testAsymmetricHoverStaysWithinTheFixedPanelAtEveryScale() {
        for scale: CGFloat in [0.875, 1, 1.15625, 1.75] {
            let panel = CGRect(x: 0, y: 0, width: 520 * scale, height: 240 * scale)
            let compact = CGRect(x: 130 * scale, y: 208 * scale, width: 387 * scale, height: 32 * scale)
            let hover = IslandPanelHoverRegion.hoverFrame(
                panelFrame: panel, compactFrame: compact, presentationState: .compact,
                isPointerInside: true,
                expandedShellSize: CGSize(width: 387.2 * scale, height: 161.92 * scale))
            XCTAssertGreaterThanOrEqual(hover.minX, panel.minX - 0.000_001)
            XCTAssertLessThanOrEqual(hover.maxX, panel.maxX + 0.000_001)
            XCTAssertEqual(hover.maxY, panel.maxY)
            XCTAssertEqual(hover.midX, compact.midX)
        }
    }

    func testWideCompactHoverDoesNotShrinkWhenExpandedShellIsDenser() {
        for scale: CGFloat in [0.875, 1, 1.15625, 1.75] {
            let panel = CGRect(x: 0, y: 0, width: 520 * scale, height: 240 * scale)
            for compact in [
                CGRect(x: 60 * scale, y: 208 * scale, width: 400 * scale, height: 32 * scale),
                CGRect(x: 80 * scale, y: 208 * scale, width: 440 * scale, height: 32 * scale)
            ] {
                let hover = IslandPanelHoverRegion.hoverFrame(
                    panelFrame: panel, compactFrame: compact, presentationState: .compact,
                    isPointerInside: true,
                    expandedShellSize: CGSize(width: 387.2 * scale, height: 161.92 * scale)
                )

                XCTAssertEqual(hover.width, compact.width, accuracy: 0.000_001)
                XCTAssertEqual(hover.midX, compact.midX, accuracy: 0.000_001)
                XCTAssertEqual(hover.maxY, compact.maxY, accuracy: 0.000_001)
                XCTAssertGreaterThan(hover.height, compact.height)
                XCTAssertGreaterThanOrEqual(hover.minX, panel.minX - 0.000_001)
                XCTAssertLessThanOrEqual(hover.maxX, panel.maxX + 0.000_001)
                XCTAssertTrue(IslandPanelHoverRegion.contains(
                    CGPoint(x: compact.minX + scale, y: compact.midY), in: hover
                ))
                XCTAssertTrue(IslandPanelHoverRegion.contains(
                    CGPoint(x: compact.maxX - scale, y: compact.midY), in: hover
                ))
            }
        }
    }

    func testAsymmetricCompactHoverStillClampsToPanelWithReducedExpandedBudget() {
        for scale: CGFloat in [0.875, 1, 1.15625, 1.75] {
            let panel = CGRect(x: 0, y: 0, width: 520 * scale, height: 240 * scale)
            let compact = CGRect(x: 167 * scale, y: 208 * scale, width: 350 * scale, height: 32 * scale)
            let hover = IslandPanelHoverRegion.hoverFrame(
                panelFrame: panel, compactFrame: compact, presentationState: .compact,
                isPointerInside: true,
                expandedShellSize: CGSize(width: 387.2 * scale, height: 161.92 * scale)
            )

            XCTAssertEqual(hover.width, 356 * scale, accuracy: 0.000_001)
            XCTAssertEqual(hover.midX, compact.midX, accuracy: 0.000_001)
            XCTAssertEqual(hover.maxX, panel.maxX, accuracy: 0.000_001)
            XCTAssertGreaterThanOrEqual(hover.minX, panel.minX - 0.000_001)
        }
    }

    func testExpandedHoverTracksReducedShellEdgesAtEveryScale() {
        for scale: CGFloat in [0.875, 1, 1.15625, 1.75] {
            let layout = makeDisplayLayout(scale: scale)
            let panel = CGRect(origin: CGPoint(x: -234 * scale, y: 900 * scale), size: layout.panelSize)
            let compact = CGRect(x: panel.midX - layout.compactSize.width / 2,
                                 y: panel.maxY - layout.compactSize.height,
                                 width: layout.compactSize.width, height: layout.compactSize.height)
            let shellSize = layout.scaledExpanded(IslandVisualStyle.expandedShellSize)
            let previousShell = IslandPanelHoverRegion.expandedShellFrame(
                in: panel, size: layout.scaled(IslandVisualStyle.expandedShellSize)
            )

            for state: IslandPresentationState in [.expanded, .dragging] {
                let hover = IslandPanelHoverRegion.hoverFrame(
                    panelFrame: panel, compactFrame: compact, presentationState: state,
                    isPointerInside: true, expandedShellSize: shellSize
                )

                XCTAssertEqual(hover.width, 387.2 * scale, accuracy: 0.000_001)
                XCTAssertEqual(hover.height, 161.92 * scale, accuracy: 0.000_001)
                XCTAssertEqual(hover.midX, panel.midX, accuracy: 0.000_001)
                XCTAssertEqual(hover.maxY, panel.maxY, accuracy: 0.000_001)
                XCTAssertTrue(IslandPanelHoverRegion.contains(
                    CGPoint(x: hover.minX + scale, y: hover.midY), in: hover
                ))
                XCTAssertTrue(IslandPanelHoverRegion.contains(
                    CGPoint(x: hover.midX, y: hover.minY + scale), in: hover
                ))
                XCTAssertFalse(IslandPanelHoverRegion.contains(
                    CGPoint(x: previousShell.minX + 4, y: hover.midY), in: hover
                ))
                XCTAssertFalse(IslandPanelHoverRegion.contains(
                    CGPoint(x: hover.midX, y: previousShell.minY + 4), in: hover
                ))
            }
        }
    }

    func testExpandedHoverRegionUsesVisibleShellInsteadOfFullTransparentPanel() {
        let panelFrame = CGRect(x: 604, y: 877, width: 520, height: 240)
        let compactFrame = CGRect(x: 756, y: 1079, width: 216, height: 38)
        let shellSize = IslandVisualStyle.expandedShellSize(
            for: .fileTray, timerMode: .stopwatch, hasTrayItems: true,
            hasError: false, hasTimerCompletion: false
        )

        let hoverFrame = IslandPanelHoverRegion.hoverFrame(
            panelFrame: panelFrame,
            compactFrame: compactFrame,
            presentationState: .dragging,
            isPointerInside: true,
            expandedShellSize: shellSize
        )

        XCTAssertEqual(hoverFrame, CGRect(x: 644, y: 969, width: 440, height: 148))
        XCTAssertTrue(IslandPanelHoverRegion.contains(CGPoint(x: hoverFrame.midX, y: hoverFrame.midY), in: hoverFrame))
        XCTAssertFalse(IslandPanelHoverRegion.contains(CGPoint(x: panelFrame.minX + 4, y: panelFrame.midY), in: hoverFrame))
        XCTAssertFalse(IslandPanelHoverRegion.contains(CGPoint(x: hoverFrame.midX, y: 930), in: hoverFrame))
    }

    private func makeDisplayLayout(scale: CGFloat) -> IslandDisplayLayout {
        let frame = CGRect(x: 0, y: 0, width: 2560, height: 1600)
        let notchWidth: CGFloat = 179 * scale
        let notchHeight: CGFloat = 32 * scale
        return IslandDisplayLayout(environment: ScreenEnvironment(
            displayID: 1,
            name: "Controlled Notched Display",
            frame: frame,
            visibleFrame: CGRect(x: 0, y: 0, width: frame.width, height: frame.height - notchHeight),
            safeAreaInsets: ScreenEdgeInsets(top: notchHeight),
            auxiliaryTopLeftArea: CGRect(x: 0, y: frame.maxY - notchHeight,
                                         width: frame.midX - notchWidth / 2, height: notchHeight),
            auxiliaryTopRightArea: CGRect(x: frame.midX + notchWidth / 2, y: frame.maxY - notchHeight,
                                          width: frame.midX - notchWidth / 2, height: notchHeight),
            backingScaleFactor: 2,
            isBuiltIn: true
        ))
    }
}
