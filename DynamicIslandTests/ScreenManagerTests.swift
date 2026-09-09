import AppKit
import CoreGraphics
import XCTest
@testable import DynamicIsland

final class ScreenManagerTests: XCTestCase {
    func testStartMonitoringUsesConfiguredSelectionPolicy() async {
        await MainActor.run {
            let builtIn = makeScreen(displayID: 1, frameOriginX: 0, isBuiltIn: true)
            let external = makeScreen(displayID: 2, frameOriginX: 1728, isBuiltIn: false)
            let snapshot = ScreenSnapshot(screens: [builtIn, external], mainDisplayID: 2)
            let manager = ScreenManager(
                selectionPolicy: .builtIn,
                notificationCenter: NotificationCenter(),
                snapshotProvider: { snapshot }
            )

            manager.startMonitoring()

            XCTAssertEqual(manager.screens, [builtIn, external])
            XCTAssertEqual(manager.activeScreen?.displayID, builtIn.displayID)
        }
    }

    func testScreenParameterNotificationMovesMainPolicyToNewMainDisplay() async {
        await MainActor.run {
            let notificationCenter = NotificationCenter()
            let builtIn = makeScreen(displayID: 1, frameOriginX: 0, isBuiltIn: true)
            let external = makeScreen(displayID: 2, frameOriginX: 1728, isBuiltIn: false)
            var snapshot = ScreenSnapshot(screens: [builtIn, external], mainDisplayID: 1)
            let manager = ScreenManager(
                selectionPolicy: .main,
                notificationCenter: notificationCenter,
                snapshotProvider: { snapshot }
            )
            manager.startMonitoring()
            XCTAssertEqual(manager.activeScreen?.displayID, builtIn.displayID)

            snapshot = ScreenSnapshot(screens: [builtIn, external], mainDisplayID: 2)
            notificationCenter.post(
                name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )

            XCTAssertEqual(manager.activeScreen?.displayID, external.displayID)
            let panelFrame = manager.activeScreen.map(IslandPanelGeometry.stableFrame(in:))
            XCTAssertNotNil(panelFrame)
            XCTAssertGreaterThanOrEqual(panelFrame?.minX ?? -.infinity, external.frame.minX)
            XCTAssertLessThanOrEqual(panelFrame?.maxX ?? .infinity, external.frame.maxX)
            XCTAssertEqual(panelFrame?.maxY ?? 0, external.frame.maxY, accuracy: 0.5)
        }
    }

    func testChangingPolicyReselectsFromLatestSnapshot() async {
        await MainActor.run {
            let builtIn = makeScreen(displayID: 1, frameOriginX: 0, isBuiltIn: true)
            let external = makeScreen(displayID: 2, frameOriginX: 1728, isBuiltIn: false)
            let snapshot = ScreenSnapshot(screens: [builtIn, external], mainDisplayID: 2)
            let manager = ScreenManager(
                selectionPolicy: .builtIn,
                notificationCenter: NotificationCenter(),
                snapshotProvider: { snapshot }
            )
            manager.startMonitoring()

            manager.setSelectionPolicy(.main)

            XCTAssertEqual(manager.selectionPolicy, .main)
            XCTAssertEqual(manager.activeScreen?.displayID, external.displayID)
        }
    }

    func testRemovedExplicitDisplayFallsBackToBuiltInDisplay() async {
        await MainActor.run {
            let notificationCenter = NotificationCenter()
            let builtIn = makeScreen(displayID: 1, frameOriginX: 0, isBuiltIn: true)
            let external = makeScreen(displayID: 2, frameOriginX: 1728, isBuiltIn: false)
            var snapshot = ScreenSnapshot(screens: [builtIn, external], mainDisplayID: 2)
            let manager = ScreenManager(
                selectionPolicy: .display(external.displayID),
                notificationCenter: notificationCenter,
                snapshotProvider: { snapshot }
            )
            manager.startMonitoring()
            XCTAssertEqual(manager.activeScreen?.displayID, external.displayID)

            snapshot = ScreenSnapshot(screens: [builtIn], mainDisplayID: builtIn.displayID)
            notificationCenter.post(
                name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )

            XCTAssertEqual(manager.screens, [builtIn])
            XCTAssertEqual(manager.activeScreen?.displayID, builtIn.displayID)
        }
    }

    func testClamshellTransitionFallsBackFromBuiltInToRemainingExternalDisplay() async {
        await MainActor.run {
            let notificationCenter = NotificationCenter()
            let builtIn = makeScreen(displayID: 1, frameOriginX: 0, isBuiltIn: true)
            let external = makeScreen(displayID: 2, frameOriginX: 1728, isBuiltIn: false)
            var snapshot = ScreenSnapshot(screens: [builtIn, external], mainDisplayID: builtIn.displayID)
            let manager = ScreenManager(
                selectionPolicy: .builtIn,
                notificationCenter: notificationCenter,
                snapshotProvider: { snapshot }
            )
            manager.startMonitoring()

            snapshot = ScreenSnapshot(screens: [external], mainDisplayID: external.displayID)
            notificationCenter.post(
                name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )

            XCTAssertEqual(manager.screens, [external])
            XCTAssertEqual(manager.physicalScreen, external)
            XCTAssertEqual(manager.activeScreen, external)
        }
    }

    func testTransientEmptySnapshotKeepsLastUsableScreenUntilDisplaysRecover() async {
        await MainActor.run {
            let notificationCenter = NotificationCenter()
            let builtIn = makeScreen(displayID: 1, frameOriginX: 0, isBuiltIn: true)
            let external = makeScreen(displayID: 2, frameOriginX: 1728, isBuiltIn: false)
            var snapshot = ScreenSnapshot(screens: [builtIn], mainDisplayID: builtIn.displayID)
            let manager = ScreenManager(
                selectionPolicy: .builtIn,
                notificationCenter: notificationCenter,
                snapshotProvider: { snapshot }
            )
            manager.startMonitoring()

            snapshot = ScreenSnapshot(screens: [], mainDisplayID: nil)
            notificationCenter.post(
                name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )

            XCTAssertTrue(manager.screens.isEmpty)
            XCTAssertEqual(manager.physicalScreen, builtIn)
            XCTAssertEqual(manager.activeScreen, builtIn)

            snapshot = ScreenSnapshot(screens: [external], mainDisplayID: external.displayID)
            notificationCenter.post(
                name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )

            XCTAssertEqual(manager.physicalScreen, external)
            XCTAssertEqual(manager.activeScreen, external)
        }
    }

    func testSimulationRemainsAvailableBeforeFirstPhysicalScreenSnapshot() async {
        await MainActor.run {
            let manager = ScreenManager(
                notificationCenter: NotificationCenter(),
                snapshotProvider: { ScreenSnapshot(screens: [], mainDisplayID: nil) }
            )
            let configuration = SimulatedScreenProfile.macBookPro14.defaultConfiguration

            manager.setSimulationConfiguration(configuration)
            manager.startMonitoring()

            XCTAssertNil(manager.physicalScreen)
            XCTAssertEqual(manager.activeScreen, configuration.makeEnvironment())
        }
    }

    func testStopMonitoringIgnoresLaterScreenNotifications() async {
        await MainActor.run {
            let notificationCenter = NotificationCenter()
            let builtIn = makeScreen(displayID: 1, frameOriginX: 0, isBuiltIn: true)
            let external = makeScreen(displayID: 2, frameOriginX: 1728, isBuiltIn: false)
            var snapshot = ScreenSnapshot(screens: [builtIn, external], mainDisplayID: 1)
            let manager = ScreenManager(
                selectionPolicy: .main,
                notificationCenter: notificationCenter,
                snapshotProvider: { snapshot }
            )
            manager.startMonitoring()
            manager.stopMonitoring()

            snapshot = ScreenSnapshot(screens: [builtIn, external], mainDisplayID: 2)
            notificationCenter.post(
                name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )

            XCTAssertEqual(manager.activeScreen?.displayID, builtIn.displayID)
        }
    }

    func testSimulationOverridesGeometryAndStaysAnchoredToPhysicalScreen() async {
        await MainActor.run {
            let physical = makeScreen(displayID: 1, frameOriginX: 1728, isBuiltIn: true)
            let snapshot = ScreenSnapshot(screens: [physical], mainDisplayID: physical.displayID)
            let manager = ScreenManager(
                notificationCenter: NotificationCenter(),
                snapshotProvider: { snapshot }
            )
            var configuration = SimulatedScreenProfile.macBookAir13.defaultConfiguration
            configuration.notchWidth = 300

            manager.startMonitoring()
            manager.setSimulationConfiguration(configuration)

            XCTAssertEqual(manager.physicalScreen, physical)
            XCTAssertEqual(manager.simulationConfiguration, configuration)
            XCTAssertEqual(manager.activeScreen?.displayID, configuration.profile.simulatedDisplayID)
            XCTAssertEqual(manager.activeScreen?.frame.size, configuration.logicalSize)
            XCTAssertEqual(manager.activeScreen?.frame.midX ?? 0, physical.frame.midX, accuracy: 0.5)
            XCTAssertEqual(manager.activeScreen?.frame.maxY ?? 0, physical.frame.maxY, accuracy: 0.5)
            XCTAssertEqual(
                manager.activeScreen.map(IslandPanelGeometry.compactFrame(in:))?.width ?? 0,
                300,
                accuracy: 0.5
            )
        }
    }

    func testSimulationReanchorsAfterMainDisplayChangeAndCanBeDisabled() async {
        await MainActor.run {
            let notificationCenter = NotificationCenter()
            let builtIn = makeScreen(displayID: 1, frameOriginX: 0, isBuiltIn: true)
            let external = makeScreen(displayID: 2, frameOriginX: 1728, isBuiltIn: false)
            var snapshot = ScreenSnapshot(screens: [builtIn, external], mainDisplayID: builtIn.displayID)
            let manager = ScreenManager(
                selectionPolicy: .main,
                notificationCenter: notificationCenter,
                snapshotProvider: { snapshot }
            )
            let configuration = SimulatedScreenProfile.external4K.defaultConfiguration
            manager.startMonitoring()
            manager.setSimulationConfiguration(configuration)

            snapshot = ScreenSnapshot(screens: [builtIn, external], mainDisplayID: external.displayID)
            notificationCenter.post(
                name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )

            XCTAssertEqual(manager.physicalScreen, external)
            XCTAssertEqual(manager.activeScreen?.frame.midX ?? 0, external.frame.midX, accuracy: 0.5)
            XCTAssertEqual(manager.activeScreen?.frame.maxY ?? 0, external.frame.maxY, accuracy: 0.5)

            manager.setSimulationConfiguration(nil)

            XCTAssertNil(manager.simulationConfiguration)
            XCTAssertEqual(manager.activeScreen, external)
        }
    }

    private func makeScreen(
        displayID: CGDirectDisplayID,
        frameOriginX: CGFloat,
        isBuiltIn: Bool
    ) -> ScreenEnvironment {
        ScreenEnvironment(
            displayID: displayID,
            name: "Display \(displayID)",
            frame: CGRect(x: frameOriginX, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: frameOriginX, y: 0, width: 1728, height: 1071),
            backingScaleFactor: 2,
            isBuiltIn: isBuiltIn
        )
    }
}
