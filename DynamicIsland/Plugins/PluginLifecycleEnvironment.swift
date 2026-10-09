import AppKit
import Foundation
import OSLog

/// Converts system events into suspension conditions without owning plugin
/// lifecycle transitions. Battery reads occur only at startup and on events.
@MainActor
public final class PluginLifecycleEnvironment {
    public nonisolated struct State: Equatable, Sendable {
        public let isSleeping: Bool
        public let isLowBattery: Bool

        public init(isSleeping: Bool = false, isLowBattery: Bool = false) {
            self.isSleeping = isSleeping
            self.isLowBattery = isLowBattery
        }
    }

    private nonisolated enum Event: Sendable {
        case sleep
        case wake
        case battery
    }

    public private(set) var state = State()

    private let notificationCenter: NotificationCenter
    private let batteryService: any BatteryService
    private let onChange: @MainActor (State) -> Void
    private let logger = Logger(subsystem: "DynamicIsland", category: "PluginLifecycleEnvironment")
    private var notificationObservers: [NSObjectProtocol] = []
    private var batteryObservation: (any BatteryObservation)?
    private var generation: UUID?
    private var lastSleepWakeSequence: UInt64 = 0

    /// Starts observing synchronously and delivers one initial state. The
    /// callback always runs on the main actor, including that initial delivery.
    public init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        batteryService: any BatteryService = IOKitBatteryService(),
        onChange: @escaping @MainActor (State) -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.batteryService = batteryService
        self.onChange = onChange
        start()
    }

    deinit {
        notificationObservers.forEach { notificationCenter.removeObserver($0) }
        batteryObservation?.cancel()
    }

    public func start() {
        guard generation == nil else { return }
        let currentGeneration = UUID()
        generation = currentGeneration
        lastSleepWakeSequence = 0
        let eventOrder = PluginSleepWakeEventOrder()

        notificationObservers = [
            (NSWorkspace.willSleepNotification, Event.sleep),
            (NSWorkspace.didWakeNotification, Event.wake)
        ].map { name, event in
            notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.receive(event, generation: currentGeneration, sequence: eventOrder.next())
            }
        }

        do {
            batteryObservation = try batteryService.observeChanges { [weak self] in
                self?.receive(.battery, generation: currentGeneration, sequence: nil)
            }
        } catch {
            logger.error("Failed to observe battery state: \(String(describing: error), privacy: .public)")
        }
        readBatteryState()
        onChange(state)
    }

    /// Invalidates queued callbacks before removing their registrations. A
    /// callback from a previous start cannot affect a later observation session.
    public func stop() {
        generation = nil
        notificationObservers.forEach { notificationCenter.removeObserver($0) }
        notificationObservers.removeAll()
        batteryObservation?.cancel()
        batteryObservation = nil
    }

    private nonisolated func receive(_ event: Event, generation: UUID, sequence: UInt64?) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                handle(event, generation: generation, sequence: sequence)
            }
        } else {
            Task { @MainActor [weak self] in
                self?.handle(event, generation: generation, sequence: sequence)
            }
        }
    }

    private func handle(_ event: Event, generation: UUID, sequence: UInt64?) {
        guard self.generation == generation else { return }
        // A newer main-thread wake may already have been delivered while an
        // earlier background sleep was waiting for MainActor admission.
        if let sequence {
            guard sequence > lastSleepWakeSequence else { return }
            lastSleepWakeSequence = sequence
        }
        let previous = state
        switch event {
        case .sleep:
            state = State(isSleeping: true, isLowBattery: state.isLowBattery)
        case .wake:
            state = State(isSleeping: false, isLowBattery: state.isLowBattery)
            readBatteryState()
        case .battery:
            readBatteryState()
        }
        if state != previous {
            onChange(state)
        }
    }

    private func readBatteryState() {
        let battery: BatteryState?
        do {
            battery = try batteryService.currentState()
        } catch {
            // A transient read failure must not clear an existing suspension.
            logger.error("Failed to read battery state: \(String(describing: error), privacy: .public)")
            return
        }

        let isLowBattery: Bool
        if let battery, battery.powerSource == .battery {
            isLowBattery = state.isLowBattery ? battery.level < 0.25 : battery.level <= 0.20
        } else {
            isLowBattery = false
        }
        state = State(isSleeping: state.isSleeping, isLowBattery: isLowBattery)
    }
}

private nonisolated final class PluginSleepWakeEventOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
