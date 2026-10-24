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

    func testCompactFrameFallsBackWhenVisibleFrameTemporarilyExtendsAboveScreen() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let transientVisibleFrame = CGRect(x: 0, y: 0, width: 1728, height: 1200)

        let frame = IslandPanelGeometry.compactFrame(
            screenFrame: screenFrame,
            visibleFrame: transientVisibleFrame,
            auxiliaryTopLeftArea: .zero,
            auxiliaryTopRightArea: .zero
        )

        XCTAssertEqual(frame.height, IslandPanelGeometry.fallbackTopReservedHeight)
        XCTAssertEqual(frame.maxY, screenFrame.maxY, accuracy: 0.5)
    }

    func testCompactSizeFallsBackForNonFiniteReservedHeight() {
        XCTAssertEqual(
            IslandPanelGeometry.compactSize(forTopReservedHeight: .infinity).height,
            IslandPanelGeometry.fallbackTopReservedHeight
        )
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

        XCTAssertEqual(frame.width, 617.5)
        XCTAssertEqual(frame.height, 285)
        XCTAssertEqual(frame.midX, 864, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, 1117, accuracy: 0.5)
    }

    func testStableFrameScalesWithNotchAndMatchesCompactCenter() {
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

        XCTAssertEqual(stable.size, CGSize(width: 617.5, height: 285))
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
        XCTAssertEqual(stable.height, 221.53846153846155, accuracy: 0.000_001)
        XCTAssertEqual(stable.width / stable.height, 520.0 / 240.0, accuracy: 0.000_001)
        XCTAssertEqual(stable.maxY, environment.frame.maxY, accuracy: 0.5)
    }

    func testHeightLimitedScreenFitsExpandedFrameWithoutChangingItsAspectRatio() {
        let environment = ScreenEnvironment(
            displayID: 3,
            name: "Synthetic Height-Limited Display",
            frame: CGRect(x: -400, y: -120, width: 400, height: 120),
            visibleFrame: CGRect(x: -400, y: -120, width: 400, height: 96),
            backingScaleFactor: 1,
            isBuiltIn: false
        )

        let stable = IslandPanelGeometry.stableFrame(in: environment)

        XCTAssertEqual(stable.size, CGSize(width: 260, height: 120))
        XCTAssertEqual(stable.midX, environment.frame.midX, accuracy: 0.5)
        XCTAssertEqual(stable.maxY, environment.frame.maxY, accuracy: 0.5)
        XCTAssertTrue(environment.frame.contains(stable))
    }

    func testNotchedFramesRemainAlignedOnScreenAboveAndLeftOfMainDisplay() {
        let screenFrame = CGRect(x: -1728, y: -120, width: 1728, height: 1117)
        let environment = ScreenEnvironment(
            displayID: 4,
            name: "Synthetic Offset Notched Display",
            frame: screenFrame,
            visibleFrame: CGRect(x: -1728, y: -120, width: 1728, height: 1071),
            safeAreaInsets: ScreenEdgeInsets(top: 38),
            auxiliaryTopLeftArea: CGRect(x: -1728, y: 959, width: 756, height: 38),
            auxiliaryTopRightArea: CGRect(x: -756, y: 959, width: 756, height: 38),
            backingScaleFactor: 2,
            isBuiltIn: true
        )

        let compact = IslandPanelGeometry.compactFrame(in: environment)
        let stable = IslandPanelGeometry.stableFrame(in: environment)

        XCTAssertEqual(compact.size, CGSize(width: 216, height: 38))
        XCTAssertEqual(stable.size, CGSize(width: 617.5, height: 285))
        XCTAssertEqual(stable.midX, compact.midX, accuracy: 0.5)
        XCTAssertEqual(stable.maxY, screenFrame.maxY, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(stable.minX, screenFrame.minX)
        XCTAssertLessThanOrEqual(stable.maxX, screenFrame.maxX)
        XCTAssertGreaterThanOrEqual(stable.minY, screenFrame.minY)
    }

    func testSynthetic1710FractionalPanelPreservesExactTopEdgeAndNotchCenter() {
        // Synthetic 37 pt notch geometry, not an additional measured device.
        let environment = ScreenEnvironment(
            displayID: 5,
            name: "Synthetic 1710 Display",
            frame: CGRect(x: 0, y: 0, width: 1710, height: 1112),
            visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1075),
            safeAreaInsets: ScreenEdgeInsets(top: 37),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 1075, width: 751, height: 37),
            auxiliaryTopRightArea: CGRect(x: 959, y: 1075, width: 751, height: 37),
            backingScaleFactor: 2,
            isBuiltIn: true
        )

        let frames = [
            IslandPanelGeometry.expandedFrame(in: environment),
            IslandPanelGeometry.stableFrame(in: environment)
        ]

        for frame in frames {
            XCTAssertEqual(frame.size, CGSize(width: 601.25, height: 277.5))
            XCTAssertEqual(frame.maxY, environment.frame.maxY, accuracy: 0.000_001)
            XCTAssertEqual(frame.midX, 855, accuracy: 0.000_001)
            XCTAssertTrue(environment.frame.contains(frame))
        }
    }
}
