import AppKit
import XCTest
@testable import DynamicIsland

final class IslandPanelStabilityMonitorTests: XCTestCase {
    func testSpaceWakeAndUnhideEventsRequestPanelRestoration() async {
        await MainActor.run {
            let workspaceCenter = NotificationCenter()
            let applicationCenter = NotificationCenter()
            var restorationCount = 0
            let monitor = IslandPanelStabilityMonitor(
                workspaceNotificationCenter: workspaceCenter,
                applicationNotificationCenter: applicationCenter,
                onStabilityEvent: { restorationCount += 1 }
            )

            monitor.start()
            workspaceCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            applicationCenter.post(name: NSApplication.didUnhideNotification, object: nil)

            XCTAssertEqual(restorationCount, 3)
        }
    }

    func testStartingTwiceDoesNotDuplicateObserversAndStopRemovesThem() async {
        await MainActor.run {
            let workspaceCenter = NotificationCenter()
            var restorationCount = 0
            let monitor = IslandPanelStabilityMonitor(
                workspaceNotificationCenter: workspaceCenter,
                applicationNotificationCenter: NotificationCenter(),
                onStabilityEvent: { restorationCount += 1 }
            )

            monitor.start()
            monitor.start()
            workspaceCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            monitor.stop()
            workspaceCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

            XCTAssertEqual(restorationCount, 1)
        }
    }
}
