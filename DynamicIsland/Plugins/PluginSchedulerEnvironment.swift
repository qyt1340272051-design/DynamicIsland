import AppKit
import Foundation

/// App activity, Workspace foreground changes and system power notifications
/// select the shared Host refresh policy without polling or retaining the scheduler.
@MainActor
public final class PluginSchedulerEnvironment {
    private weak var scheduler: PluginScheduler?
    private let notificationCenter: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let isActive: @MainActor () -> Bool
    private let isFrontmost: @MainActor () -> Bool
    private let isLowPowerModeEnabled: @MainActor () -> Bool
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var generation: UUID?

    public init(
        scheduler: PluginScheduler,
        notificationCenter: NotificationCenter = .default,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        isActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
        isFrontmost: @escaping @MainActor () -> Bool = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == ProcessInfo.processInfo.processIdentifier
        },
        isLowPowerModeEnabled: @escaping @MainActor () -> Bool = {
            ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    ) {
        self.scheduler = scheduler
        self.notificationCenter = notificationCenter
        self.workspaceCenter = workspaceCenter
        self.isActive = isActive
        self.isFrontmost = isFrontmost
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        start()
    }

    deinit {
        observers.forEach { notificationCenter.removeObserver($0) }
        workspaceObservers.forEach { workspaceCenter.removeObserver($0) }
    }

    /// Observation starts once and immediately applies the current policy.
    public func start() {
        guard generation == nil else { return }
        let currentGeneration = UUID()
        generation = currentGeneration
        observers = [NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification,
                     .NSProcessInfoPowerStateDidChange].map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.receive(generation: currentGeneration)
            }
        }
        workspaceObservers = [NSWorkspace.didActivateApplicationNotification,
                              NSWorkspace.didDeactivateApplicationNotification].map { name in
            workspaceCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.receive(generation: currentGeneration)
            }
        }
        updatePolicy()
    }

    /// Invalidate already queued notifications before unregistering observers.
    public func stop() {
        generation = nil
        observers.forEach { notificationCenter.removeObserver($0) }
        observers.removeAll()
        workspaceObservers.forEach { workspaceCenter.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    private nonisolated func receive(generation: UUID) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { handle(generation: generation) }
        } else {
            Task { @MainActor [weak self] in self?.handle(generation: generation) }
        }
    }

    private func handle(generation: UUID) {
        guard self.generation == generation else { return }
        // Read current state after actor admission. An older queued notification
        // cannot restore a stale foreground or power snapshot after a new one.
        updatePolicy()
    }

    private func updatePolicy() {
        let policy: PluginSchedulerPolicy = isLowPowerModeEnabled()
            ? .lowPower : (isActive() && isFrontmost() ? .active : .background)
        scheduler?.setPolicy(policy)
    }
}
