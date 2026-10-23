import CoreGraphics
import XCTest
@testable import DynamicIsland

final class IslandDisplayLayoutTests: XCTestCase {
    func testRecorded1470DefaultConfigurationKeepsReferenceDesignSize() {
        let layout = IslandDisplayLayout(environment: recordedDefaultEnvironment())

        XCTAssertEqual(layout.scale, 1, accuracy: 0.000_001)
        assertSize(layout.compactSize, equals: CGSize(width: 179, height: 32))
        assertSize(layout.designCompactSize, equals: CGSize(width: 179, height: 32))
        assertSize(layout.panelSize, equals: CGSize(width: 520, height: 240))
    }

    func testRecorded1280ConfigurationKeepsDesignProportionRelativeToNotch() {
        let layout = IslandDisplayLayout(environment: recordedNonDefaultEnvironment())

        XCTAssertEqual(layout.scale, 0.875, accuracy: 0.000_001)
        assertSize(layout.compactSize, equals: CGSize(width: 156, height: 28))
        assertSize(layout.panelSize, equals: CGSize(width: 455, height: 210))
        XCTAssertEqual(layout.designCompactSize.height, 32, accuracy: 0.000_001)
        assertSize(layout.scaled(CGSize(width: 480, height: 200)),
                   equals: CGSize(width: 420, height: 175))
        assertSize(layout.unscaled(layout.panelSize), equals: CGSize(width: 520, height: 240))
    }

    func testSynthetic1710ConfigurationScalesFrom37PointNotchHeight() {
        // This configuration exercises a larger logical size; it is not a
        // measured hardware or System Settings acceptance result.
        let environment = makeNotchedEnvironment(
            frame: CGRect(x: 0, y: 0, width: 1710, height: 1112),
            notchWidth: 208,
            notchHeight: 37
        )
        let layout = IslandDisplayLayout(environment: environment)

        XCTAssertEqual(layout.scale, 1.15625, accuracy: 0.000_001)
        assertSize(layout.compactSize, equals: CGSize(width: 208, height: 37))
        assertSize(layout.panelSize, equals: CGSize(width: 601.25, height: 277.5))
        XCTAssertEqual(layout.designCompactSize.height, 32, accuracy: 0.000_001)
        assertSize(layout.scaled(layout.designCompactSize), equals: layout.compactSize)
    }

    func testBackingScaleDoesNotChangeLogicalLayout() {
        let layouts = [CGFloat(1), 2, 3].map {
            IslandDisplayLayout(environment: recordedNonDefaultEnvironment(backingScaleFactor: $0))
        }

        for layout in layouts {
            XCTAssertEqual(layout.scale, 0.875, accuracy: 0.000_001)
            assertSize(layout.compactSize, equals: CGSize(width: 156, height: 28))
            assertSize(layout.panelSize, equals: CGSize(width: 455, height: 210))
        }
    }

    func testNormalizedCompactSizeRestoresMeasuredNotchGapWithoutDoubleScaling() {
        let environment = recordedNonDefaultEnvironment()
        let layout = IslandDisplayLayout(environment: environment)
        let measuredGap = environment.auxiliaryTopRightArea.minX
            - environment.auxiliaryTopLeftArea.maxX

        XCTAssertEqual(layout.designCompactSize.width, 178.28571428571428, accuracy: 0.000_001)
        XCTAssertEqual(layout.scaled(layout.designCompactSize).width, measuredGap, accuracy: 0.000_001)
        XCTAssertEqual(layout.scaled(layout.designCompactSize).height, 28, accuracy: 0.000_001)
    }

    func testNegativeScreenOriginDoesNotChangeLayoutScaleOrBudget() {
        let environment = makeNotchedEnvironment(
            frame: CGRect(x: -1470, y: -956, width: 1470, height: 956),
            notchWidth: 179,
            notchHeight: 32,
            notchCenterOffset: 0.5
        )
        let layout = IslandDisplayLayout(environment: environment)
        let reference = IslandDisplayLayout(environment: recordedDefaultEnvironment())

        XCTAssertEqual(layout.scale, reference.scale, accuracy: 0.000_001)
        assertSize(layout.compactSize, equals: reference.compactSize)
        assertSize(layout.designCompactSize, equals: reference.designCompactSize)
        assertSize(layout.panelSize, equals: reference.panelSize)
    }

    func testNonNotchedDisplayUsesReferenceScaleInsteadOfMenuBarHeight() {
        let environment = ScreenEnvironment(
            displayID: 2,
            name: "Synthetic External Display",
            frame: CGRect(x: 1470, y: -120, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1470, y: -120, width: 1920, height: 1042),
            backingScaleFactor: 2,
            isBuiltIn: false
        )
        let layout = IslandDisplayLayout(environment: environment)

        XCTAssertFalse(environment.hasNotch)
        XCTAssertEqual(layout.scale, 1, accuracy: 0.000_001)
        assertSize(layout.panelSize, equals: CGSize(width: 520, height: 240))
        assertSize(layout.compactSize, equals: CGSize(width: 260, height: 38))
    }

    func testNarrowDisplayFitsPanelUniformlyAndKeepsActualNotchGap() {
        let environment = makeNotchedEnvironment(
            frame: CGRect(x: -360, y: 100, width: 360, height: 260),
            notchWidth: 160,
            notchHeight: 28
        )
        let layout = IslandDisplayLayout(environment: environment)

        XCTAssertEqual(layout.scale, 0.6923076923076923, accuracy: 0.000_001)
        assertSize(layout.panelSize, equals: CGSize(width: 360, height: 166.15384615384616))
        assertSize(layout.compactSize, equals: CGSize(width: 160, height: 28))
        assertSize(layout.scaled(layout.designCompactSize), equals: layout.compactSize)
        XCTAssertEqual(layout.panelSize.width / layout.panelSize.height,
                       520.0 / 240.0, accuracy: 0.000_001)
    }

    func testShortDisplayFitsHeightWithoutStretchingPanel() {
        let environment = ScreenEnvironment(
            displayID: 3,
            name: "Synthetic Short Display",
            frame: CGRect(x: 0, y: -120, width: 400, height: 120),
            visibleFrame: CGRect(x: 0, y: -120, width: 400, height: 96),
            backingScaleFactor: 1,
            isBuiltIn: false
        )
        let layout = IslandDisplayLayout(environment: environment)

        XCTAssertEqual(layout.scale, 0.5, accuracy: 0.000_001)
        assertSize(layout.panelSize, equals: CGSize(width: 260, height: 120))
        assertSize(layout.unscaled(layout.panelSize), equals: CGSize(width: 520, height: 240))
    }

    func testMenuBarVisibilityDoesNotResizeTheSamePhysicalNotch() {
        let frame = CGRect(x: 0, y: 0, width: 1280, height: 832)
        let environments = [
            CGRect(x: 0, y: 58, width: 1280, height: 746),
            frame
        ].map { visibleFrame in
            makeNotchedEnvironment(frame: frame, notchWidth: 156, notchHeight: 28,
                                  visibleFrame: visibleFrame)
        }

        for environment in environments {
            let layout = IslandDisplayLayout(environment: environment)
            XCTAssertEqual(layout.scale, 0.875, accuracy: 0.000_001)
            assertSize(layout.compactSize, equals: CGSize(width: 156, height: 28))
            assertSize(layout.panelSize, equals: CGSize(width: 455, height: 210))
        }
    }

    func testInfiniteAuxiliaryHeightDoesNotTurnFallbackHeightIntoLayoutScale() {
        let environment = ScreenEnvironment(
            displayID: 4,
            name: "Synthetic Invalid Auxiliary Strip",
            frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
            visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 924),
            safeAreaInsets: ScreenEdgeInsets(top: 32),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 924, width: 646, height: CGFloat.infinity),
            auxiliaryTopRightArea: CGRect(x: 825, y: 924, width: 645, height: CGFloat.infinity),
            backingScaleFactor: 2,
            isBuiltIn: true
        )
        let layout = IslandDisplayLayout(environment: environment)

        XCTAssertEqual(layout.scale, 1, accuracy: 0.000_001)
        assertSize(layout.panelSize, equals: CGSize(width: 520, height: 240))
        XCTAssertTrue(layout.compactSize.width.isFinite)
        XCTAssertTrue(layout.compactSize.height.isFinite)
    }

    func testScreenEnvironmentSwitchRestoresBothScaleAndActualCompactGeometry() async {
        let defaultEnvironment = recordedDefaultEnvironment()
        let nonDefaultEnvironment = recordedNonDefaultEnvironment()

        await MainActor.run {
            let model = IslandViewModel.preview()
            model.setScreenEnvironment(defaultEnvironment)
            XCTAssertEqual(model.displayLayout.scale, 1, accuracy: 0.000_001)
            XCTAssertEqual(model.compactPanelSize, CGSize(width: 179, height: 32))

            model.setScreenEnvironment(nonDefaultEnvironment)
            XCTAssertEqual(model.displayLayout.scale, 0.875, accuracy: 0.000_001)
            XCTAssertEqual(model.compactPanelSize, CGSize(width: 156, height: 28))
            XCTAssertEqual(model.displayLayout.panelSize, CGSize(width: 455, height: 210))

            model.setScreenEnvironment(defaultEnvironment)
            XCTAssertEqual(model.displayLayout.scale, 1, accuracy: 0.000_001)
            XCTAssertEqual(model.compactPanelSize, CGSize(width: 179, height: 32))
            XCTAssertEqual(model.displayLayout.panelSize, CGSize(width: 520, height: 240))
        }
    }

    func testScreenFitUpdatesWhenActualCompactSizeDoesNotChange() async {
        let wide = ScreenEnvironment(
            displayID: 2,
            name: "Synthetic Wide External Display",
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1056),
            backingScaleFactor: 1,
            isBuiltIn: false
        )
        let narrow = ScreenEnvironment(
            displayID: 3,
            name: "Synthetic Narrow External Display",
            frame: CGRect(x: -480, y: 0, width: 480, height: 900),
            visibleFrame: CGRect(x: -480, y: 0, width: 480, height: 876),
            backingScaleFactor: 2,
            isBuiltIn: false
        )

        await MainActor.run {
            let model = IslandViewModel.preview()
            model.setScreenEnvironment(wide)
            let originalCompactSize = model.compactPanelSize
            XCTAssertEqual(model.displayLayout.scale, 1, accuracy: 0.000_001)

            model.setScreenEnvironment(narrow)

            XCTAssertEqual(model.compactPanelSize, originalCompactSize)
            XCTAssertEqual(model.displayLayout.scale, 0.9230769230769231, accuracy: 0.000_001)
            XCTAssertEqual(model.displayLayout.panelSize.width, 480, accuracy: 0.000_001)
            XCTAssertEqual(model.displayLayout.panelSize.height, 221.53846153846155,
                           accuracy: 0.000_001)
        }
    }

    func testLegacyCompactSizeSetterKeepsUnscaledCallerContract() async {
        let environment = recordedNonDefaultEnvironment()

        await MainActor.run {
            let model = IslandViewModel.preview()
            model.setScreenEnvironment(environment)
            XCTAssertEqual(model.displayLayout.scale, 0.875, accuracy: 0.000_001)

            model.setCompactPanelSize(CGSize(width: 179, height: 32))

            XCTAssertEqual(model.displayLayout.scale, 1, accuracy: 0.000_001)
            XCTAssertEqual(model.compactPanelSize, CGSize(width: 179, height: 32))
            XCTAssertEqual(model.displayLayout.panelSize, CGSize(width: 520, height: 240))
        }
    }

    private func recordedDefaultEnvironment() -> ScreenEnvironment {
        makeNotchedEnvironment(
            frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
            notchWidth: 179,
            notchHeight: 32,
            notchCenterOffset: 0.5,
            visibleFrame: CGRect(x: 0, y: 64, width: 1470, height: 860)
        )
    }

    private func recordedNonDefaultEnvironment(backingScaleFactor: CGFloat = 2) -> ScreenEnvironment {
        makeNotchedEnvironment(
            frame: CGRect(x: 0, y: 0, width: 1280, height: 832),
            notchWidth: 156,
            notchHeight: 28,
            backingScaleFactor: backingScaleFactor,
            visibleFrame: CGRect(x: 0, y: 58, width: 1280, height: 746)
        )
    }

    private func makeNotchedEnvironment(
        frame: CGRect,
        notchWidth: CGFloat,
        notchHeight: CGFloat,
        notchCenterOffset: CGFloat = 0,
        backingScaleFactor: CGFloat = 2,
        visibleFrame: CGRect? = nil
    ) -> ScreenEnvironment {
        let center = frame.midX + notchCenterOffset
        let leftMaxX = center - notchWidth / 2
        let rightMinX = center + notchWidth / 2
        let auxiliaryY = frame.maxY - notchHeight
        return ScreenEnvironment(
            displayID: 1,
            name: "Controlled Notched Display",
            frame: frame,
            visibleFrame: visibleFrame ?? CGRect(x: frame.minX, y: frame.minY,
                                                width: frame.width, height: frame.height - notchHeight),
            safeAreaInsets: ScreenEdgeInsets(top: notchHeight),
            auxiliaryTopLeftArea: CGRect(x: frame.minX, y: auxiliaryY,
                                         width: leftMaxX - frame.minX, height: notchHeight),
            auxiliaryTopRightArea: CGRect(x: rightMinX, y: auxiliaryY,
                                          width: frame.maxX - rightMinX, height: notchHeight),
            backingScaleFactor: backingScaleFactor,
            isBuiltIn: true
        )
    }

    private func assertSize(_ actual: CGSize, equals expected: CGSize,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.000_001, file: file, line: line)
    }
}
