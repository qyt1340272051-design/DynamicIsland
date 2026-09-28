import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class BatteryActivityProviderTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 96_000)

    func testInitialHealthyAndChargingStatesRemainSilent() async throws {
        let healthy = BatteryActivityTestService(state: battery(0.64))
        let healthyManager = ActivityManager(configuration: .immediate)
        let healthyProvider = BatteryActivityProvider(
            service: healthy,
            manager: healthyManager,
            debounceNanoseconds: 0
        )

        try await settle()
        XCTAssertNil(healthyManager.activity(id: BatteryActivityProvider.activityID))
        healthy.emit(battery(0.63))
        try await settle()
        XCTAssertNil(healthyManager.current)

        let charging = BatteryActivityTestService(state: battery(
            0.51,
            powerSource: .ac,
            isCharging: true
        ))
        let chargingManager = ActivityManager(configuration: .immediate)
        let chargingProvider = BatteryActivityProvider(
            service: charging,
            manager: chargingManager,
            debounceNanoseconds: 0
        )

        try await settle()
        XCTAssertNil(chargingManager.activity(id: BatteryActivityProvider.activityID))
        charging.emit(battery(0.52, powerSource: .ac, isCharging: true))
        try await settle()
        XCTAssertNil(chargingManager.current)

        withExtendedLifetime((healthyProvider, chargingProvider)) {}
    }

    func testInitialLowAndCriticalStatesAreNotMissed() async throws {
        let lowService = BatteryActivityTestService(state: battery(0.20))
        let lowManager = ActivityManager(configuration: .immediate)
        let lowProvider = BatteryActivityProvider(
            service: lowService,
            manager: lowManager,
            debounceNanoseconds: 0
        )
        try await waitFor { lowManager.current?.id == BatteryActivityProvider.activityID }

        XCTAssertEqual(lowManager.current?.priority, .important)
        XCTAssertEqual(lowManager.current?.lifecycle.policy, .transient)

        let criticalService = BatteryActivityTestService(state: battery(0.10))
        let criticalManager = ActivityManager(configuration: .immediate)
        let criticalProvider = BatteryActivityProvider(
            service: criticalService,
            manager: criticalManager,
            debounceNanoseconds: 0
        )
        try await waitFor { criticalManager.current?.id == BatteryActivityProvider.activityID }

        XCTAssertEqual(criticalManager.current?.priority, .critical)
        XCTAssertEqual(criticalManager.current?.lifecycle.policy, .critical)
        withExtendedLifetime((lowProvider, criticalProvider)) {}
    }

    func testChargingPublishesProgressUpdatesOneInstanceAndDoesNotRepublishAfterExpiry() async throws {
        let clock = TestActivityClock(start)
        let manager = makeManager(clock: clock)
        let music = try publishMusic(on: manager)
        let musicToken = try XCTUnwrap(manager.currentSnapshot?.instanceToken)
        let service = BatteryActivityTestService(state: battery(0.60))
        let provider = BatteryActivityProvider(
            service: service,
            manager: manager,
            debounceNanoseconds: 0,
            now: clock.now
        )

        service.emit(battery(0.63, powerSource: .ac, isCharging: true))
        try await waitFor { manager.current?.presentation.progress == 0.63 }
        let first = try XCTUnwrap(manager.currentSnapshot)

        XCTAssertEqual(first.activity.id, BatteryActivityProvider.activityID)
        XCTAssertEqual(first.activity.priority, .normal)
        XCTAssertEqual(first.activity.lifecycle.policy, .transient)
        XCTAssertEqual(first.activity.presentation.progress ?? -1, 0.63, accuracy: 0.000_1)

        service.emit(battery(0.67, powerSource: .ac, isCharging: true))
        try await waitFor { manager.current?.presentation.progress == 0.67 }
        let updated = try XCTUnwrap(manager.currentSnapshot)
        XCTAssertEqual(updated.instanceToken, first.instanceToken)

        clock.advance(by: 3.1)
        manager.processDeadlines()
        XCTAssertNil(manager.activity(id: BatteryActivityProvider.activityID))
        XCTAssertEqual(manager.current?.id, music.id)
        XCTAssertEqual(manager.currentSnapshot?.instanceToken, musicToken)

        service.emit(battery(0.68, powerSource: .ac, isCharging: true))
        try await settle()
        XCTAssertNil(manager.activity(id: BatteryActivityProvider.activityID))
        XCTAssertEqual(manager.current?.id, music.id)

        service.emit(battery(0.68))
        try await settle()
        service.emit(battery(0.69, powerSource: .ac, isCharging: true))
        try await waitFor { manager.current?.id == BatteryActivityProvider.activityID }
        XCTAssertNotEqual(manager.currentSnapshot?.instanceToken, first.instanceToken)
        withExtendedLifetime(provider) {}
    }

    func testLowBatteryUsesImportantTransientAndUpdatesSameInstance() async throws {
        let clock = TestActivityClock(start)
        let manager = makeManager(clock: clock)
        let service = BatteryActivityTestService(state: battery(0.50))
        let provider = BatteryActivityProvider(
            service: service,
            manager: manager,
            debounceNanoseconds: 0,
            now: clock.now
        )

        service.emit(battery(0.20))
        try await waitFor { manager.current?.priority == .important }
        let first = try XCTUnwrap(manager.currentSnapshot)
        XCTAssertEqual(first.activity.lifecycle.policy, .transient)
        XCTAssertEqual(first.activity.presentation.progress ?? -1, 0.20, accuracy: 0.000_1)

        service.emit(battery(0.18))
        try await waitFor { manager.current?.presentation.progress == 0.18 }
        let updated = try XCTUnwrap(manager.currentSnapshot)
        XCTAssertEqual(updated.activity.id, first.activity.id)
        XCTAssertEqual(updated.instanceToken, first.instanceToken)
        withExtendedLifetime(provider) {}
    }

    func testThresholdHysteresisPreventsLowAndCriticalPriorityFlapping() async throws {
        let clock = TestActivityClock(start)
        let manager = makeManager(clock: clock)
        let service = BatteryActivityTestService(state: battery(0.30))
        let provider = BatteryActivityProvider(
            service: service,
            manager: manager,
            debounceNanoseconds: 0,
            now: clock.now
        )

        service.emit(battery(0.20))
        try await waitFor { manager.current?.priority == .important }
        let low = try XCTUnwrap(manager.currentSnapshot)

        service.emit(battery(0.21))
        try await waitFor { manager.current?.presentation.progress == 0.21 }
        XCTAssertEqual(manager.current?.priority, .important)
        XCTAssertEqual(manager.currentSnapshot?.instanceToken, low.instanceToken)

        service.emit(battery(0.10))
        try await waitFor { manager.current?.priority == .critical }
        let critical = try XCTUnwrap(manager.currentSnapshot)
        XCTAssertEqual(critical.activity.id, low.activity.id)
        XCTAssertNotEqual(critical.instanceToken, low.instanceToken)
        XCTAssertEqual(critical.activity.lifecycle.policy, .critical)

        service.emit(battery(0.11))
        try await waitFor { manager.current?.presentation.progress == 0.11 }
        XCTAssertEqual(manager.current?.priority, .critical)
        XCTAssertEqual(manager.currentSnapshot?.instanceToken, critical.instanceToken)

        service.emit(battery(0.13))
        try await waitFor { manager.current?.priority == .important }
        let recoveredLow = try XCTUnwrap(manager.currentSnapshot)
        XCTAssertEqual(recoveredLow.activity.id, critical.activity.id)
        XCTAssertNotEqual(recoveredLow.instanceToken, critical.instanceToken)

        service.emit(battery(0.21))
        try await waitFor { manager.current?.presentation.progress == 0.21 }
        XCTAssertEqual(manager.currentSnapshot?.instanceToken, recoveredLow.instanceToken)

        service.emit(battery(0.23))
        try await waitFor { manager.activity(id: BatteryActivityProvider.activityID) == nil }
        XCTAssertNil(manager.current)
        withExtendedLifetime(provider) {}
    }

    func testCriticalUpdateDoesNotExtendDeadlineAndRecoveryAllowsASecondAlert() async throws {
        let clock = TestActivityClock(start)
        let manager = makeManager(clock: clock)
        let music = try publishMusic(on: manager)
        let musicToken = try XCTUnwrap(manager.currentSnapshot?.instanceToken)
        let service = BatteryActivityTestService(state: battery(0.50))
        let provider = BatteryActivityProvider(
            service: service,
            manager: manager,
            debounceNanoseconds: 0,
            now: clock.now
        )

        service.emit(battery(0.09))
        try await waitFor { manager.current?.priority == .critical }
        let first = try XCTUnwrap(manager.currentSnapshot)

        clock.advance(by: 4)
        service.emit(battery(0.08))
        try await waitFor { manager.current?.presentation.progress == 0.08 }
        XCTAssertEqual(manager.currentSnapshot?.instanceToken, first.instanceToken)

        clock.advance(by: 1.1)
        manager.processDeadlines()
        XCTAssertEqual(manager.current?.id, music.id)
        XCTAssertEqual(manager.currentSnapshot?.instanceToken, musicToken)
        XCTAssertEqual(
            manager.activity(id: BatteryActivityProvider.activityID)?.lifecycle.state,
            .dismissed
        )

        service.emit(battery(0.07))
        try await waitFor {
            manager.activity(id: BatteryActivityProvider.activityID)?.presentation.progress == 0.07
        }
        XCTAssertEqual(manager.current?.id, music.id)
        XCTAssertEqual(
            manager.activity(id: BatteryActivityProvider.activityID)?.lifecycle.state,
            .dismissed
        )

        service.emit(battery(0.07, powerSource: .ac, isCharged: true))
        try await waitFor { manager.activity(id: BatteryActivityProvider.activityID) == nil }
        XCTAssertEqual(manager.current?.id, music.id)

        service.emit(battery(0.09))
        try await waitFor { manager.current?.priority == .critical }
        XCTAssertNotEqual(manager.currentSnapshot?.instanceToken, first.instanceToken)
        withExtendedLifetime(provider) {}
    }

    func testProviderReadsOnlyAtStartupAndOnObservedChangesAndCancelsObservation() async throws {
        let clock = TestActivityClock(start)
        let manager = makeManager(clock: clock)
        let service = BatteryActivityTestService(state: battery(0.50))
        var provider: BatteryActivityProvider? = BatteryActivityProvider(
            service: service,
            manager: manager,
            debounceNanoseconds: 0,
            now: clock.now
        )

        try await waitFor { service.readCount == 1 && service.observerCount == 1 }
        clock.advance(by: 3_600)
        manager.processDeadlines()
        try await settle()
        XCTAssertEqual(service.readCount, 1)

        service.emit(battery(0.19))
        try await waitFor { service.readCount == 2 }
        XCTAssertEqual(manager.current?.priority, .important)

        provider = nil
        try await waitFor { service.observerCount == 0 }
        XCTAssertEqual(service.cancelCount, 1)
        withExtendedLifetime(provider) {}
    }

    func testDebounceCoalescesPowerSourceNotificationBurstIntoOneRead() async throws {
        let manager = ActivityManager(configuration: .immediate)
        let service = BatteryActivityTestService(state: battery(0.50))
        let provider = BatteryActivityProvider(
            service: service,
            manager: manager,
            debounceNanoseconds: 80_000_000
        )

        XCTAssertEqual(service.readCount, 1)
        service.emit(battery(0.19))
        service.emit(battery(0.09))
        service.emit(battery(0.08))

        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(service.readCount, 1)
        XCTAssertNil(manager.current)

        try await waitFor {
            manager.current?.presentation.progress == 0.08
        }
        XCTAssertEqual(service.readCount, 2)
        XCTAssertEqual(manager.current?.priority, .critical)
        withExtendedLifetime(provider) {}
    }

    func testFactoryUsesFixedIdentityNoActionsAndHostSafePresentations() {
        let cases: [(BatteryActivityProvider.Classification, BatteryState, ActivityPriority, ActivityLifecycle.Policy)] = [
            (.charging, battery(0.63, powerSource: .ac, isCharging: true), .normal, .transient),
            (.low, battery(0.18), .important, .transient),
            (.critical, battery(0.08), .critical, .critical)
        ]

        for (classification, state, priority, policy) in cases {
            let activity = BatteryActivityProvider.makeActivity(
                for: state,
                classification: classification,
                createdAt: start
            )

            XCTAssertEqual(activity.id, "builtin.battery")
            XCTAssertEqual(
                activity.source,
                ActivitySource(kind: .builtIn, identifier: "battery")
            )
            XCTAssertEqual(activity.priority, priority)
            XCTAssertEqual(activity.lifecycle.policy, policy)
            XCTAssertEqual(activity.presentation.progress ?? -1, state.level, accuracy: 0.000_1)
            XCTAssertTrue(activity.actions.isEmpty)
            if policy == .transient {
                XCTAssertEqual(
                    activity.expiresAt,
                    start.addingTimeInterval(BatteryActivityProvider.presentationDuration)
                )
            } else {
                XCTAssertNil(activity.expiresAt)
            }

            for mode in ActivityPresentation.Mode.allCases {
                let node = activity.presentation.resolvedNode(for: mode)
                XCTAssertTrue(
                    ActivityPresentation.HostPolicy.accepts(node, for: mode),
                    "\(classification) \(mode)"
                )
            }
        }
    }

    private func makeManager(clock: TestActivityClock) -> ActivityManager {
        ActivityManager(
            clock: clock,
            configuration: ActivityScheduler.Configuration(
                transientDuration: 3,
                criticalMaximumDuration: 5,
                ordinaryDebounce: 0,
                minimumDwell: 0
            )
        )
    }

    @discardableResult
    private func publishMusic(on manager: ActivityManager) throws -> IslandActivity {
        let music = IslandActivity(
            id: "test.music",
            source: ActivitySource(kind: .builtIn, identifier: "test-music"),
            priority: .background,
            lifecycle: ActivityLifecycle(policy: .persistent),
            presentation: ActivityPresentation(title: "音乐"),
            createdAt: start
        )
        try manager.publish(music)
        return music
    }

    private func battery(
        _ level: Double,
        powerSource: BatteryPowerSource = .battery,
        isCharging: Bool = false,
        isCharged: Bool = false
    ) -> BatteryState {
        BatteryState(
            level: level,
            powerSource: powerSource,
            isCharging: isCharging,
            isCharged: isCharged
        )
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for Battery Activity")
    }
}

private final class BatteryActivityTestService: BatteryService, @unchecked Sendable {
    private let lock = NSLock()
    private var state: BatteryState?
    private var observers: [UUID: @Sendable () -> Void] = [:]
    private var reads = 0
    private var cancellations = 0

    init(state: BatteryState?) {
        self.state = state
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    var observerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return observers.count
    }

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellations
    }

    func currentState() throws -> BatteryState? {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return state
    }

    func observeChanges(
        _ handler: @escaping @Sendable () -> Void
    ) throws -> BatteryObservation? {
        let id = UUID()
        lock.lock()
        observers[id] = handler
        lock.unlock()
        return BatteryActivityTestObservation(service: self, id: id)
    }

    func emit(_ next: BatteryState?) {
        let callbacks: [@Sendable () -> Void]
        lock.lock()
        state = next
        callbacks = Array(observers.values)
        lock.unlock()
        callbacks.forEach { $0() }
    }

    fileprivate func cancelObservation(id: UUID) {
        lock.lock()
        if observers.removeValue(forKey: id) != nil {
            cancellations += 1
        }
        lock.unlock()
    }
}

private final class BatteryActivityTestObservation: BatteryObservation, @unchecked Sendable {
    private let lock = NSLock()
    private weak var service: BatteryActivityTestService?
    private var id: UUID?

    init(service: BatteryActivityTestService, id: UUID) {
        self.service = service
        self.id = id
    }

    deinit {
        cancel()
    }

    nonisolated func cancel() {
        let cancellation: (BatteryActivityTestService, UUID)?
        lock.lock()
        if let service, let id {
            cancellation = (service, id)
            self.id = nil
        } else {
            cancellation = nil
        }
        lock.unlock()
        if let cancellation {
            cancellation.0.cancelObservation(id: cancellation.1)
        }
    }
}
