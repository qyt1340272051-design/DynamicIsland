import CoreGraphics
import XCTest
@testable import DynamicIsland

final class IslandPanelGeometryTests: XCTestCase {
    func testCompactFrameUsesAuxiliaryNotchHeightWhenAvailable() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1728, height: 1071)
        let left = CGRect(x: 0, y: 1079, width: 756, height: 38)
        let right = CGRect(x: 972, y: 1079, width: 756, height: 38)

        let frame = IslandPanelGeometry.compactFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            auxiliaryTopLeftArea: left,
            auxiliaryTopRightArea: right
        )

        XCTAssertEqual(frame.width, right.minX - left.maxX)
        XCTAssertEqual(frame.height, 38)
        XCTAssertEqual(frame.midX, 864, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, 1117, accuracy: 0.5)
        XCTAssertEqual(frame.minY, left.minY, accuracy: 0.5)
    }

    func testCompactFrameFallsBackToDefaultMenuBarHeightWhenSafeAreaIsUnavailable() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)

        let frame = IslandPanelGeometry.compactFrame(
            screenFrame: screenFrame,
            visibleFrame: screenFrame,
            auxiliaryTopLeftArea: .zero,
            auxiliaryTopRightArea: .zero
        )

        XCTAssertEqual(frame.width, 260)
        XCTAssertEqual(frame.height, IslandPanelGeometry.fallbackTopReservedHeight)
        XCTAssertEqual(frame.midX, screenFrame.midX, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, screenFrame.maxY, accuracy: 0.5)
    }

    func testExpandedFrameKeepsTopEdgeOverlappingNotchArea() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let left = CGRect(x: 0, y: 1079, width: 756, height: 38)
        let right = CGRect(x: 972, y: 1079, width: 756, height: 38)

        let frame = IslandPanelGeometry.expandedFrame(
            screenFrame: screenFrame,
            auxiliaryTopLeftArea: left,
            auxiliaryTopRightArea: right,
            safeAreaInsetsTop: 38
        )

        XCTAssertEqual(frame.width, 520)
        XCTAssertEqual(frame.height, 240)
        XCTAssertEqual(frame.midX, 864, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, 1117, accuracy: 0.5)
    }

    func testStableFrameUsesExpandedSizeAndMatchesCompactCenter() {
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
        let stable = IslandPanelGeometry.stableFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            auxiliaryTopLeftArea: left,
            auxiliaryTopRightArea: right
        )

        XCTAssertEqual(stable.size, IslandPanelGeometry.expandedSize)
        XCTAssertEqual(stable.midX, compact.midX, accuracy: 0.5)
        XCTAssertEqual(stable.maxY, compact.maxY, accuracy: 0.5)
    }

    func testFramesNormalizeAuxiliaryAreasWhenScreenHasNonZeroOrigin() {
        let screenFrame = CGRect(x: 1728, y: 0, width: 1728, height: 1117)
        let visibleFrame = CGRect(x: 1728, y: 0, width: 1728, height: 1071)
        let localLeft = CGRect(x: 0, y: 1079, width: 756, height: 38)
        let localRight = CGRect(x: 972, y: 1079, width: 756, height: 38)

        let compact = IslandPanelGeometry.compactFrame(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            auxiliaryTopLeftArea: localLeft,
            auxiliaryTopRightArea: localRight
        )
        let expanded = IslandPanelGeometry.expandedFrame(
            screenFrame: screenFrame,
            auxiliaryTopLeftArea: localLeft,
            auxiliaryTopRightArea: localRight,
            safeAreaInsetsTop: 38
        )

        XCTAssertEqual(compact.midX, screenFrame.midX, accuracy: 0.5)
        XCTAssertEqual(expanded.midX, compact.midX, accuracy: 0.5)
        XCTAssertTrue(screenFrame.contains(CGPoint(x: expanded.midX, y: expanded.midY)))
    }

    func testEnvironmentFramesRemainInsideOffsetNarrowScreen() {
        let environment = ScreenEnvironment(
            displayID: 2,
            name: "Narrow External Display",
            frame: CGRect(x: 1728, y: -120, width: 480, height: 900),
            visibleFrame: CGRect(x: 1728, y: -120, width: 480, height: 876),
            backingScaleFactor: 1,
            isBuiltIn: false
        )

        let compact = IslandPanelGeometry.compactFrame(in: environment)
        let stable = IslandPanelGeometry.stableFrame(in: environment)

        for frame in [compact, stable] {
            XCTAssertGreaterThanOrEqual(frame.minX, environment.frame.minX)
            XCTAssertLessThanOrEqual(frame.maxX, environment.frame.maxX)
            XCTAssertGreaterThanOrEqual(frame.minY, environment.frame.minY)
            XCTAssertLessThanOrEqual(frame.maxY, environment.frame.maxY)
        }
        XCTAssertEqual(stable.width, environment.frame.width)
        XCTAssertEqual(stable.maxY, environment.frame.maxY, accuracy: 0.5)
    }
}
