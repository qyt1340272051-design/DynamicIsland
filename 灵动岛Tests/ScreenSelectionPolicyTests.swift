import CoreGraphics
import XCTest
@testable import DynamicIsland

final class ScreenSelectionPolicyTests: XCTestCase {
    func testBuiltInPolicyPrefersBuiltInDisplayOverMainDisplay() {
        let builtIn = makeScreen(displayID: 1, isBuiltIn: true)
        let external = makeScreen(displayID: 2, isBuiltIn: false)

        let selected = ScreenSelectionPolicy.builtIn.select(
            from: [external, builtIn],
            mainDisplayID: external.displayID
        )

        XCTAssertEqual(selected?.displayID, builtIn.displayID)
    }

    func testBuiltInPolicyFallsBackToMainDisplayWhenNoBuiltInDisplayExists() {
        let firstExternal = makeScreen(displayID: 1, isBuiltIn: false)
        let mainExternal = makeScreen(displayID: 2, isBuiltIn: false)

        let selected = ScreenSelectionPolicy.builtIn.select(
            from: [firstExternal, mainExternal],
            mainDisplayID: mainExternal.displayID
        )

        XCTAssertEqual(selected?.displayID, mainExternal.displayID)
    }

    func testMainPolicyTracksCurrentMainDisplay() {
        let builtIn = makeScreen(displayID: 1, isBuiltIn: true)
        let external = makeScreen(displayID: 2, isBuiltIn: false)

        let selected = ScreenSelectionPolicy.main.select(
            from: [builtIn, external],
            mainDisplayID: external.displayID
        )

        XCTAssertEqual(selected?.displayID, external.displayID)
    }

    func testMissingExplicitDisplayFallsBackToBuiltInDisplay() {
        let builtIn = makeScreen(displayID: 1, isBuiltIn: true)
        let external = makeScreen(displayID: 2, isBuiltIn: false)

        let selected = ScreenSelectionPolicy.display(99).select(
            from: [external, builtIn],
            mainDisplayID: external.displayID
        )

        XCTAssertEqual(selected?.displayID, builtIn.displayID)
    }

    func testEmptyDisplayListHasNoSelection() {
        XCTAssertNil(ScreenSelectionPolicy.builtIn.select(from: [], mainDisplayID: nil))
    }

    private func makeScreen(displayID: CGDirectDisplayID, isBuiltIn: Bool) -> ScreenEnvironment {
        ScreenEnvironment(
            displayID: displayID,
            name: "Display \(displayID)",
            frame: CGRect(x: CGFloat(displayID - 1) * 1920, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: CGFloat(displayID - 1) * 1920, y: 0, width: 1920, height: 1056),
            isBuiltIn: isBuiltIn
        )
    }
}
