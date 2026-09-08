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
