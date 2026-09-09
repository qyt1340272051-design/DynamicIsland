import AppKit
import XCTest
@testable import DynamicIsland

final class IslandPanelWindowPolicyTests: XCTestCase {
    func testPolicyKeepsPanelAvailableAcrossSpacesAndFullScreenApps() async {
        await MainActor.run {
            let behavior = IslandPanelWindowPolicy.collectionBehavior

            XCTAssertTrue(behavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(behavior.contains(.fullScreenAuxiliary))
            XCTAssertTrue(behavior.contains(.stationary))
            XCTAssertTrue(behavior.contains(.ignoresCycle))
        }
    }

    func testApplyingPolicyKeepsPanelIndependentFromApplicationActivation() async {
        await MainActor.run {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )

            IslandPanelWindowPolicy.apply(to: panel)

            XCTAssertEqual(panel.collectionBehavior, IslandPanelWindowPolicy.collectionBehavior)
            XCTAssertEqual(panel.level, .statusBar)
            XCTAssertFalse(panel.hidesOnDeactivate)
            XCTAssertFalse(panel.canHide)
            XCTAssertTrue(panel.isFloatingPanel)
            XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
            XCTAssertTrue(panel.worksWhenModal)
            XCTAssertTrue(panel.isExcludedFromWindowsMenu)
            XCTAssertFalse(panel.isReleasedWhenClosed)
            XCTAssertEqual(panel.animationBehavior, .none)
        }
    }
}
