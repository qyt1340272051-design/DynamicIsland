import AppKit
import XCTest
@testable import DynamicIsland

final class HapticFeedbackServiceTests: XCTestCase {
    func testExpansionFeedbackUsesSinglePulsePattern() {
        XCTAssertEqual(TrackpadHapticFeedbackService.expansionPattern, .generic)
    }
}
