import AppKit
import Combine

@MainActor
final class IslandPanelStabilityMonitor {
    private let workspaceNotificationCenter: NotificationCenter
    private let applicationNotificationCenter: NotificationCenter
    private let onStabilityEvent: () -> Void
    private var observations: [AnyCancellable] = []

    init(
        workspaceNotificationCenter: NotificationCenter,
        applicationNotificationCenter: NotificationCenter,
        onStabilityEvent: @escaping () -> Void
    ) {
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.applicationNotificationCenter = applicationNotificationCenter
        self.onStabilityEvent = onStabilityEvent
    }

    func start() {
        guard observations.isEmpty else {
            return
        }

        observations = [
            workspaceNotificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
            workspaceNotificationCenter.publisher(for: NSWorkspace.didWakeNotification),
            applicationNotificationCenter.publisher(for: NSApplication.didUnhideNotification),
        ].map { publisher in
            publisher.sink { [weak self] _ in
                self?.onStabilityEvent()
            }
        }
    }

    func stop() {
        observations.forEach { $0.cancel() }
        observations.removeAll()
    }
}
