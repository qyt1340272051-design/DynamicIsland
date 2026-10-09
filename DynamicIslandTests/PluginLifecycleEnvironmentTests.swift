import AppKit
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginLifecycleEnvironmentTests: XCTestCase {
    func testInitialSnapshotAndSleepWakeKeepConditionsIndependent() {
        let center = NotificationCenter()
        let service = LifecycleEnvironmentBatteryService(state: battery(0.15))
        var states: [PluginLifecycleEnvironment.State] = []
        let environment = PluginLifecycleEnvironment(
            notificationCenter: center,
            batteryService: service,
            onChange: { states.append($0) }
        )

        XCTAssertEqual(states, [.init(isLowBattery: true)])
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(environment.state, .init(isSleeping: true, isLowBattery: true))
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(environment.state, .init(isLowBattery: true))
        XCTAssertEqual(states.count, 3)

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        service.emit(battery(0.15, source: .ac))
        XCTAssertEqual(environment.state, .init(isSleeping: true))
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(environment.state, .init())
    }

    func testLowBatteryThresholdHysteresisAndExternalPowerRecovery() {
        let service = LifecycleEnvironmentBatteryService(state: battery(0.21))
        var states: [PluginLifecycleEnvironment.State] = []
        let environment = PluginLifecycleEnvironment(
            notificationCenter: NotificationCenter(),
            batteryService: service,
            onChange: { states.append($0) }
        )

        service.emit(battery(0.20))
        XCTAssertTrue(environment.state.isLowBattery)
        service.emit(battery(0.21))
        service.emit(battery(0.249))
        XCTAssertTrue(environment.state.isLowBattery)
        XCTAssertEqual(states.count, 2)
        service.emit(battery(0.25))
        XCTAssertFalse(environment.state.isLowBattery)
        service.emit(battery(0.22))
        XCTAssertFalse(environment.state.isLowBattery)
        service.emit(battery(0.10))
        XCTAssertTrue(environment.state.isLowBattery)
        // AC clears the condition even before the charging flag settles.
        service.emit(battery(0.10, source: .ac))
        XCTAssertFalse(environment.state.isLowBattery)
        XCTAssertEqual(states.count, 5)
    }

    func testStopRemovesObserversAndRejectsRetainedBatteryCallbackAfterRestart() {
        let center = NotificationCenter()
        let service = LifecycleEnvironmentBatteryService(state: battery(0.70))
        var states: [PluginLifecycleEnvironment.State] = []
        let environment = PluginLifecycleEnvironment(
            notificationCenter: center,
            batteryService: service,
            onChange: { states.append($0) }
        )
        let staleCallback = service.lastCallback

        environment.stop()
        XCTAssertEqual(service.observerCount, 0)
        XCTAssertEqual(service.cancelCount, 1)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        service.emit(battery(0.10))
        staleCallback?()
        XCTAssertEqual(states, [.init()])
        XCTAssertEqual(service.readCount, 1)

        service.setState(battery(0.70))
        environment.start()
        XCTAssertEqual(service.observerCount, 1)
        XCTAssertEqual(states.count, 2)
        service.setState(battery(0.10))
        staleCallback?()
        XCTAssertFalse(environment.state.isLowBattery)
        XCTAssertEqual(service.readCount, 2)
    }

    func testRepeatedStartDoesNotRegisterOrPublishAgainAndReadsOnlyOnEvents() {
        let center = NotificationCenter()
        let service = LifecycleEnvironmentBatteryService(state: battery(0.70))
        var states: [PluginLifecycleEnvironment.State] = []
        let environment = PluginLifecycleEnvironment(
            notificationCenter: center,
            batteryService: service,
            onChange: { states.append($0) }
        )
        environment.start()
        environment.start()
        XCTAssertEqual(service.observerCount, 1)
        XCTAssertEqual(service.readCount, 1)
        XCTAssertEqual(states.count, 1)

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(service.readCount, 1)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(states.count, 3)
        XCTAssertEqual(service.readCount, 2)
        environment.stop()
    }

    func testQueuedBackgroundNotificationCannotUpdateAfterStop() async {
        let center = NotificationCenter()
        let service = LifecycleEnvironmentBatteryService(state: battery(0.70))
        var states: [PluginLifecycleEnvironment.State] = []
        let environment = PluginLifecycleEnvironment(
            notificationCenter: center,
            batteryService: service,
            onChange: { states.append($0) }
        )
        // Main actor remains occupied until stop, so receive can only enqueue
        // the background event. Its captured generation must then be rejected.
        let delivered = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            center.post(name: NSWorkspace.willSleepNotification, object: nil)
            delivered.signal()
        }
        XCTAssertEqual(delivered.wait(timeout: .now() + 1), .success)
        environment.stop()
        await Task.yield()
        XCTAssertEqual(environment.state, .init())
        XCTAssertEqual(states, [.init()])
    }

    func testNoBatteryAndFailedSnapshotDoNotInventOrClearLowBattery() {
        let service = LifecycleEnvironmentBatteryService(state: nil)
        var states: [PluginLifecycleEnvironment.State] = []
        let environment = PluginLifecycleEnvironment(
            notificationCenter: NotificationCenter(),
            batteryService: service,
            onChange: { states.append($0) }
        )
        XCTAssertEqual(states, [.init()])
        service.emit(battery(0.10))
        XCTAssertTrue(environment.state.isLowBattery)
        service.failSnapshot = true
        service.emit(nil)
        XCTAssertTrue(environment.state.isLowBattery)
        XCTAssertEqual(states.count, 2)
        service.failSnapshot = false
        service.emit(nil)
        XCTAssertFalse(environment.state.isLowBattery)
    }

    func testQueuedOlderSleepCannotOverrideNewerSynchronousWake() async throws {
        let center = NotificationCenter()
        let service = LifecycleEnvironmentBatteryService(state: battery(0.70))
        var states: [PluginLifecycleEnvironment.State] = []
        let environment = PluginLifecycleEnvironment(
            notificationCenter: center,
            batteryService: service,
            onChange: { states.append($0) }
        )
        let delivered = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            center.post(name: NSWorkspace.willSleepNotification, object: nil)
            delivered.signal()
        }
        XCTAssertEqual(delivered.wait(timeout: .now() + 1), .success)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        // Let the older MainActor task run after the newer wake has committed.
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertFalse(environment.state.isSleeping)
        XCTAssertEqual(states, [.init()])
        environment.stop()
    }

    private func battery(_ level: Double, source: BatteryPowerSource = .battery) -> BatteryState {
        BatteryState(level: level, powerSource: source, isCharging: false, isCharged: false)
    }
}

private final class LifecycleEnvironmentBatteryService: BatteryService, @unchecked Sendable {
    private var state: BatteryState?
    private var callback: (@Sendable () -> Void)?
    private(set) var lastCallback: (@Sendable () -> Void)?
    private(set) var readCount = 0
    private(set) var cancelCount = 0
    var failSnapshot = false
    var observerCount: Int { callback == nil ? 0 : 1 }

    init(state: BatteryState?) {
        self.state = state
    }

    func currentState() throws -> BatteryState? {
        readCount += 1
        if failSnapshot { throw BatteryServiceError.snapshotUnavailable }
        return state
    }

    func observeChanges(_ handler: @escaping @Sendable () -> Void) throws -> (any BatteryObservation)? {
        callback = handler
        lastCallback = handler
        return LifecycleEnvironmentBatteryObservation { [weak self] in
            self?.callback = nil
            self?.cancelCount += 1
        }
    }

    func setState(_ state: BatteryState?) {
        self.state = state
    }

    func emit(_ state: BatteryState?) {
        self.state = state
        callback?()
    }
}

private nonisolated final class LifecycleEnvironmentBatteryObservation: BatteryObservation, @unchecked Sendable {
    private let onCancel: @Sendable () -> Void

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        onCancel()
    }
}
