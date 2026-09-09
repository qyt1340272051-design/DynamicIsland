import XCTest
@testable import DynamicIsland

final class IslandPanelFrameUpdatePolicyTests: XCTestCase {
    func testPresentationStateChangesDoNotAnimatePanelFrame() {
        XCTAssertFalse(IslandPanelFrameUpdatePolicy.animatesPresentationStateChanges)
    }
}
