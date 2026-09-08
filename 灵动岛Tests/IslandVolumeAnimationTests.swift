import XCTest
@testable import DynamicIsland

final class IslandVolumeAnimationTests: XCTestCase {
    func testButtonAdjustmentUsesShortVisibleSliderTravel() {
        XCTAssertGreaterThan(IslandVolumeAnimation.sliderTravelDuration, 0.1)
        XCTAssertLessThan(IslandVolumeAnimation.sliderTravelDuration, 0.35)
    }

    func testMuteSlashDrawsAtAReadableSpeed() {
        XCTAssertGreaterThan(IslandVolumeAnimation.muteSlashDuration, 0.15)
        XCTAssertLessThan(IslandVolumeAnimation.muteSlashDuration, 0.4)
    }

    func testMutedSpeakerRemainsVisibleBehindSlash() {
        XCTAssertGreaterThan(IslandVolumeAnimation.muteIconDimmedOpacity, 0)
        XCTAssertLessThan(IslandVolumeAnimation.muteIconDimmedOpacity, 1)
    }
}
