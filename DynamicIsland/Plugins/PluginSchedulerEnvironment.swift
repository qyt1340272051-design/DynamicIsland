import AppKit
import Foundation

/// App activity and system power notifications select the shared Host refresh
/// policy. No polling is needed and this observer does not retain its scheduler.
@MainActor
public final class PluginSchedulerEnvironment {
    private weak var scheduler: PluginScheduler?
    private let notificationCenter: NotificationCenter
    private let isActive: @MainActor () -> Bool
    private let isLowPowerModeEnabled: @MainActor () -> Bool
    private var observers: [NSObjectProtocol] = []
    private var generation: UUID?

    public init(
        scheduler: PluginScheduler,
        notificationCenter: NotificationCenter = .default,
        isActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
        isLowPowerModeEnabled: @escaping @MainActor () -> Bool = {
            ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    ) {
        self.scheduler = scheduler
        self.notificationCenter = notificationCenter
        self.isActive = isActive
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        start()
    }

    deinit {
        observers.forEach { notificationCenter.removeObserver($0) }
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
        updatePolicy()
    }

    /// Invalidate already queued notifications before unregistering observers.
    public func stop() {
        generation = nil
        observers.forEach { notificationCenter.removeObserver($0) }
        observers.removeAll()
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
            ? .lowPower : (isActive() ? .active : .background)
        scheduler?.setPolicy(policy)
    }
}
