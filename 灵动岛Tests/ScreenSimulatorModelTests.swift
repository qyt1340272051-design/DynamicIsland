#if DEBUG
import CoreGraphics
import XCTest
@testable import DynamicIsland

final class ScreenSimulatorModelTests: XCTestCase {
    func testEnablingAndDisablingModelUpdatesScreenManager() async {
        await MainActor.run {
            let physical = makeScreen()
            let snapshot = ScreenSnapshot(screens: [physical], mainDisplayID: physical.displayID)
            let manager = ScreenManager(
                notificationCenter: NotificationCenter(),
                snapshotProvider: { snapshot }
            )
            manager.startMonitoring()
            let model = ScreenSimulatorModel(screenManager: manager)

            model.setEnabled(true)

            XCTAssertNotNil(manager.simulationConfiguration)
            XCTAssertEqual(manager.activeScreen?.displayID, model.configuration.profile.simulatedDisplayID)

            model.setEnabled(false)

            XCTAssertNil(manager.simulationConfiguration)
            XCTAssertEqual(manager.activeScreen, physical)
        }
    }

    func testSelectingProfileRestoresItsDefaultsAndAppliesImmediately() async {
        await MainActor.run {
            let physical = makeScreen()
            let snapshot = ScreenSnapshot(screens: [physical], mainDisplayID: physical.displayID)
            let manager = ScreenManager(
                notificationCenter: NotificationCenter(),
                snapshotProvider: { snapshot }
            )
            manager.startMonitoring()
            let model = ScreenSimulatorModel(screenManager: manager)
            model.setEnabled(true)
            model.setNotchWidth(340)

            model.selectProfile(.external4K)

            XCTAssertEqual(model.configuration, SimulatedScreenProfile.external4K.defaultConfiguration)
            XCTAssertEqual(manager.simulationConfiguration, model.configuration)
            XCTAssertFalse(model.configuration.simulatesNotch)
            XCTAssertEqual(model.configuration.pixelSize, CGSize(width: 3840, height: 2160))
        }
    }

    func testAdjustmentsAreNormalizedBeforeBeingApplied() async {
        await MainActor.run {
            let physical = makeScreen()
            let snapshot = ScreenSnapshot(screens: [physical], mainDisplayID: physical.displayID)
            let manager = ScreenManager(
                notificationCenter: NotificationCenter(),
                snapshotProvider: { snapshot }
            )
            manager.startMonitoring()
            let model = ScreenSimulatorModel(screenManager: manager)
            model.setEnabled(true)

            model.setNotchWidth(5_000)
            model.setNotchHeight(1)
            model.setScaleFactor(9)

            XCTAssertEqual(model.configuration.notchWidth, ScreenSimulationConfiguration.maximumNotchWidth)
            XCTAssertEqual(model.configuration.notchHeight, ScreenSimulationConfiguration.minimumNotchHeight)
            XCTAssertEqual(model.configuration.scaleFactor, ScreenSimulationConfiguration.maximumScaleFactor)
            XCTAssertEqual(manager.simulationConfiguration, model.configuration)
        }
    }

    @MainActor
    private func makeScreen() -> ScreenEnvironment {
        ScreenEnvironment(
            displayID: 1,
            name: "Physical Display",
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1079),
            isBuiltIn: true
        )
    }
}
#endif
