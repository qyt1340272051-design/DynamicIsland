import CoreGraphics
import XCTest
@testable import DynamicIsland

final class SimulatedScreenProfileTests: XCTestCase {
    func testProfilesCoverNotchedMacBooksAndExternalDisplays() {
        XCTAssertEqual(SimulatedScreenProfile.allCases.count, 8)
        XCTAssertEqual(
            SimulatedScreenProfile.allCases.filter(\.hasNotchByDefault).count,
            4
        )
        XCTAssertEqual(
            SimulatedScreenProfile.allCases.filter { !$0.isBuiltIn }.count,
            4
        )
    }

    func testRetinaExternalProfilesProduceExpectedPixelSizes() {
        XCTAssertEqual(
            SimulatedScreenProfile.external4K.defaultConfiguration.pixelSize,
            CGSize(width: 3840, height: 2160)
        )
        XCTAssertEqual(
            SimulatedScreenProfile.external5K.defaultConfiguration.pixelSize,
            CGSize(width: 5120, height: 2880)
        )
    }

    func testNotchedProfileBuildsSeparatedAuxiliaryAreas() {
        var configuration = SimulatedScreenProfile.macBookPro14.defaultConfiguration
        configuration.notchWidth = 280
        configuration.notchHeight = 42

        let environment = configuration.makeEnvironment()

        XCTAssertTrue(environment.hasNotch)
        XCTAssertEqual(environment.safeAreaInsets.top, 42)
        XCTAssertEqual(
            environment.auxiliaryTopRightArea.minX - environment.auxiliaryTopLeftArea.maxX,
            280,
            accuracy: 0.5
        )
        XCTAssertEqual(environment.auxiliaryTopLeftArea.height, 42)
        XCTAssertEqual(environment.auxiliaryTopRightArea.height, 42)
    }

    func testExternalProfileHasNoNotchByDefault() {
        let environment = SimulatedScreenProfile.external1440p.defaultConfiguration.makeEnvironment()

        XCTAssertFalse(environment.hasNotch)
        XCTAssertEqual(environment.safeAreaInsets, .zero)
        XCTAssertTrue(environment.auxiliaryTopLeftArea.isEmpty)
        XCTAssertTrue(environment.auxiliaryTopRightArea.isEmpty)
        XCTAssertEqual(environment.frame.maxY - environment.visibleFrame.maxY, 24)
    }

    func testConfigurationNormalizesAdjustableGeometry() {
        let configuration = ScreenSimulationConfiguration(
            profile: .macBookAir13,
            simulatesNotch: true,
            notchWidth: 2_000,
            notchHeight: 4,
            scaleFactor: 9
        ).normalized

        XCTAssertEqual(configuration.notchWidth, ScreenSimulationConfiguration.maximumNotchWidth)
        XCTAssertEqual(configuration.notchHeight, ScreenSimulationConfiguration.minimumNotchHeight)
        XCTAssertEqual(configuration.scaleFactor, ScreenSimulationConfiguration.maximumScaleFactor)
    }

    func testSimulationAnchorsTopCenterToPhysicalScreen() {
        let physicalScreen = ScreenEnvironment(
            displayID: 12,
            name: "Physical Display",
            frame: CGRect(x: 1728, y: -140, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 1728, y: -140, width: 1728, height: 1079),
            isBuiltIn: true
        )

        let environment = SimulatedScreenProfile.external5K.defaultConfiguration
            .makeEnvironment(anchoredTo: physicalScreen)

        XCTAssertEqual(environment.frame.midX, physicalScreen.frame.midX, accuracy: 0.5)
        XCTAssertEqual(environment.frame.maxY, physicalScreen.frame.maxY, accuracy: 0.5)
    }
}
