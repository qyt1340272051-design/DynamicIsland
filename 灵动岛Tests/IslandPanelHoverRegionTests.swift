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

    func testExpandedHoverRegionUsesVisibleShellInsteadOfFullTransparentPanel() {
        let panelFrame = CGRect(x: 604, y: 877, width: 520, height: 240)
        let compactFrame = CGRect(x: 756, y: 1079, width: 216, height: 38)

        let hoverFrame = IslandPanelHoverRegion.hoverFrame(
            panelFrame: panelFrame,
            compactFrame: compactFrame,
            presentationState: .dragging,
            isPointerInside: true,
            expandedShellSize: CGSize(width: 500, height: 220)
        )

        XCTAssertEqual(hoverFrame, CGRect(x: 614, y: 897, width: 500, height: 220))
        XCTAssertTrue(IslandPanelHoverRegion.contains(CGPoint(x: hoverFrame.midX, y: hoverFrame.midY), in: hoverFrame))
        XCTAssertFalse(IslandPanelHoverRegion.contains(CGPoint(x: panelFrame.minX + 4, y: panelFrame.midY), in: hoverFrame))
    }
}
