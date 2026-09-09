import CoreGraphics
import XCTest
@testable import DynamicIsland

final class ScreenEnvironmentTests: XCTestCase {
    func testHasNotchRequiresSafeInsetAndTwoSeparatedAuxiliaryAreas() {
        let notchedScreen = makeScreen(
            safeAreaTop: 38,
            leftArea: CGRect(x: 0, y: 1079, width: 756, height: 38),
            rightArea: CGRect(x: 972, y: 1079, width: 756, height: 38)
        )
        let externalScreen = makeScreen()
        let incompleteGeometry = makeScreen(
            safeAreaTop: 38,
            leftArea: CGRect(x: 0, y: 1079, width: 756, height: 38)
        )

        XCTAssertTrue(notchedScreen.hasNotch)
        XCTAssertFalse(externalScreen.hasNotch)
        XCTAssertFalse(incompleteGeometry.hasNotch)
    }

    private func makeScreen(
        safeAreaTop: CGFloat = 0,
        leftArea: CGRect = .zero,
        rightArea: CGRect = .zero
    ) -> ScreenEnvironment {
        ScreenEnvironment(
            displayID: 1,
            name: "Test Display",
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1071),
            safeAreaInsets: ScreenEdgeInsets(top: safeAreaTop),
            auxiliaryTopLeftArea: leftArea,
            auxiliaryTopRightArea: rightArea,
            backingScaleFactor: 2,
            isBuiltIn: true
        )
    }
}
