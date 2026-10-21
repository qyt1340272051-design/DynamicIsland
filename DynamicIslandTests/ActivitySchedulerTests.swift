import Foundation
import XCTest
@testable import DynamicIsland

nonisolated final class TestActivityClock: ActivityClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        date.addTimeInterval(seconds)
        lock.unlock()
    }

    func sleep(until deadline: Date) async throws {
        while now() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

@MainActor
final class ActivitySchedulerTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 32_000)

    func testTransientDurationAndAbsoluteExpiryAreSeparate() throws {
        let clock = TestActivityClock(start)
        let manager = ActivityManager(clock: clock, configuration: .immediate)
        let music = make("music", source: "music", priority: .background, policy: .persistent)
        var hint = make("hint", source: "hint", priority: .normal, policy: .transient)
        hint.expiresAt = start.addingTimeInterval(10)
        try manager.publish(music)
        try manager.publish(hint)
        XCTAssertEqual(manager.current?.id, "hint")
        clock.advance(by: 1)
        hint.presentation.title = "updated"
        try manager.update(hint)
        clock.advance(by: 2)
        manager.processDeadlines()
        XCTAssertEqual(manager.current?.id, "music")
        XCTAssertNil(manager.activity(id: "hint"))

        var expiring = make("expiring", source: "expiring", priority: .normal, policy: .persistent)
        expiring.expiresAt = clock.now().addingTimeInterval(1)
        try manager.publish(expiring)
        clock.advance(by: 1)
        manager.processDeadlines()
        XCTAssertNil(manager.activity(id: "expiring"))
    }

    func testCriticalMaximumDismissesAndRestoresPersistent() throws {
        let clock = TestActivityClock(start)
        let manager = ActivityManager(clock: clock, configuration: .immediate)
        try manager.publish(make("music", source: "music", priority: .background, policy: .persistent))
        try manager.publish(make("critical", source: "battery", priority: .critical, policy: .critical))
        XCTAssertEqual(manager.current?.id, "critical")
        clock.advance(by: 5)
        manager.processDeadlines()
        XCTAssertEqual(manager.current?.id, "music")
        XCTAssertEqual(manager.activity(id: "critical")?.lifecycle.state, .dismissed)
    }

    func testTwentyNormalEventsStayBoundedAndCriticalBypassesDebounce() throws {
        let clock = TestActivityClock(start)
        let manager = ActivityManager(clock: clock)
        try manager.publish(make("music", source: "music", priority: .background, policy: .persistent))
        for index in 0..<20 {
            try manager.publish(make("normal-\(index)", source: "plugin", priority: .normal, policy: .transient))
        }
        XCTAssertEqual(manager.current?.id, "music")
        let retained = (0..<20).compactMap { manager.activity(id: "normal-\($0)") }
        XCTAssertLessThanOrEqual(retained.count, 8)
        try manager.publish(make("critical", source: "battery", priority: .critical, policy: .critical))
        XCTAssertEqual(manager.current?.id, "critical")
        try manager.end(id: "critical", source: ActivitySource(kind: .builtIn, identifier: "battery"))
        XCTAssertTrue(manager.current?.id.hasPrefix("normal-") == true)
        clock.advance(by: 0.5)
        manager.processDeadlines()
        XCTAssertTrue(manager.current?.id.hasPrefix("normal-") == true)
        clock.advance(by: 8)
        manager.processDeadlines()
        XCTAssertEqual(manager.current?.id, "music")
    }

    func testSourceMinimumIntervalDefersPeerAfterPreviousEnds() throws {
        let clock = TestActivityClock(start)
        let source = ActivitySource(kind: .plugin, identifier: "plugin")
        let config = ActivityScheduler.Configuration(ordinaryDebounce: 0, minimumDwell: 0, minimumIntervalBySource: [source: 2])
        let manager = ActivityManager(clock: clock, configuration: config)
        let first = make("first", source: "plugin", priority: .normal, policy: .transient)
        let second = make("second", source: "plugin", priority: .normal, policy: .transient)
        try manager.publish(first)
        try manager.publish(second)
        try manager.end(id: "first", source: source)
        XCTAssertNil(manager.current)
        clock.advance(by: 2)
        manager.processDeadlines()
        XCTAssertEqual(manager.current?.id, "second")
    }

    func testLiveSchedulerAutomaticallyEndsTransient() async throws {
        let config = ActivityScheduler.Configuration(
            transientDuration: 0.03,
            ordinaryDebounce: 0,
            minimumDwell: 0,
            maximumQueuedAge: 1
        )
        let manager = ActivityManager(configuration: config)
        let createdAt = Date()
        let source = ActivitySource(kind: .builtIn, identifier: "live-test")
        let activity = IslandActivity(
            id: "live",
            source: source,
            priority: .normal,
            lifecycle: ActivityLifecycle(policy: .transient),
            presentation: ActivityPresentation(title: "live"),
            createdAt: createdAt
        )
        try manager.publish(activity)
        XCTAssertEqual(manager.current?.id, "live")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(manager.current)
        XCTAssertNil(manager.activity(id: "live"))
    }

    func testHostCanRenewTransientButTotalDisplayIsBounded() throws {
        let clock = TestActivityClock(start)
        let config = ActivityScheduler.Configuration(maximumTransientContinuousDuration: 4)
        let manager = ActivityManager(clock: clock, configuration: config)
        let hint = make("volume", source: "volume", priority: .normal, policy: .transient)
        try manager.publish(hint)
        clock.advance(by: 2.9)
        try manager.renewTransientPresentation(id: "volume", source: hint.source)
        clock.advance(by: 0.2)
        manager.processDeadlines()
        XCTAssertEqual(manager.current?.id, "volume")
        XCTAssertThrowsError(try manager.renewTransientPresentation(id: "volume", source: ActivitySource(kind: .plugin, identifier: "other"))) {
            XCTAssertEqual($0 as? ActivityManagerError, .sourceMismatch)
        }
        clock.advance(by: 1)
        manager.processDeadlines()
        XCTAssertNil(manager.current)
        XCTAssertNil(manager.activity(id: "volume"))
    }

    func testZeroAndNegativeDurationsDoNotLeavePermanentPresentation() throws {
        let clock = TestActivityClock(start)
        let config = ActivityScheduler.Configuration(transientDuration: 0, criticalMaximumDuration: -1)
        let manager = ActivityManager(clock: clock, configuration: config)
        let transient = make("brief", source: "brief", priority: .normal, policy: .transient)
        try manager.publish(transient)
        clock.advance(by: 0.002)
        manager.processDeadlines()
        XCTAssertNil(manager.activity(id: "brief"))

        let critical = make("critical", source: "battery", priority: .critical, policy: .critical)
        try manager.publish(critical)
        clock.advance(by: 0.002)
        manager.processDeadlines()
        XCTAssertNil(manager.current)
        XCTAssertEqual(manager.activity(id: "critical")?.lifecycle.state, .dismissed)
    }

    func testFutureCreatedAtCannotProtectQueuedEventFromCapacityLimit() throws {
        let clock = TestActivityClock(start)
        let config = ActivityScheduler.Configuration(maximumQueuedNormal: 1)
        let manager = ActivityManager(clock: clock, configuration: config)
        try manager.publish(make("music", source: "music", priority: .background, policy: .persistent))
        let future = IslandActivity(
            id: "a-future", source: ActivitySource(kind: .plugin, identifier: "plugin"),
            priority: .normal, lifecycle: ActivityLifecycle(policy: .transient),
            presentation: ActivityPresentation(title: "future"),
            createdAt: start.addingTimeInterval(86_400)
        )
        try manager.publish(future)
        try manager.publish(make("z-legitimate", source: "plugin", priority: .normal, policy: .transient))
        XCTAssertNil(manager.activity(id: "a-future"))
        XCTAssertEqual(manager.activity(id: "z-legitimate")?.createdAt, start)
    }

    private func make(_ id: String, source: String, priority: ActivityPriority, policy: ActivityLifecycle.Policy) -> IslandActivity {
        IslandActivity(id: id, source: ActivitySource(kind: source == "plugin" ? .plugin : .builtIn, identifier: source), priority: priority, lifecycle: ActivityLifecycle(policy: policy), presentation: ActivityPresentation(title: id), createdAt: start)
    }
}
