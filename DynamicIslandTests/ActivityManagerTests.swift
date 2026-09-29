import Combine
import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class ActivityManagerTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 30_000)
    private let musicSource = ActivitySource(kind: .builtIn, identifier: "music")
    private let pluginSource = ActivitySource(kind: .plugin, identifier: "example.plugin")

    func testPublishUpdateRetainsIdentityCreationAndLifecycle() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        try manager.publish(make("music", source: musicSource, priority: .background, policy: .persistent))
        XCTAssertEqual(manager.current?.lifecycle.state, .presented)

        var update = make("music", source: musicSource, priority: .important, policy: .persistent)
        update.lifecycle = ActivityLifecycle(state: .queued, policy: .persistent)
        update.presentation.title = "updated"
        try manager.update(update)
        XCTAssertEqual(manager.current?.presentation.title, "updated")
        XCTAssertEqual(manager.current?.lifecycle.state, .presented)
        XCTAssertEqual(manager.current?.createdAt, start)
    }

    func testDismissHidesButDoesNotEndAndOwnerIsRequired() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        try manager.publish(make("music", source: musicSource, priority: .background, policy: .persistent))
        XCTAssertThrowsError(try manager.dismiss(id: "music", source: pluginSource))
        try manager.dismiss(id: "music", source: musicSource)
        XCTAssertNil(manager.current)
        XCTAssertEqual(manager.activity(id: "music")?.lifecycle.state, .dismissed)
        try manager.update(make("music", source: musicSource, priority: .background, policy: .persistent))
        XCTAssertNil(manager.current)
        try manager.end(id: "music", source: musicSource)
        XCTAssertNil(manager.activity(id: "music"))
    }

    func testCrossSourceCollisionAndExpiredPublishAreRejected() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        try manager.publish(make("shared", source: musicSource, priority: .background, policy: .persistent))
        XCTAssertThrowsError(try manager.publish(make("shared", source: pluginSource, priority: .important, policy: .transient))) {
            XCTAssertEqual($0 as? ActivityManagerError, .sourceMismatch)
        }
        var expired = make("old", source: pluginSource, priority: .normal, policy: .transient)
        expired.expiresAt = start
        XCTAssertThrowsError(try manager.publish(expired)) {
            XCTAssertEqual($0 as? ActivityManagerError, .expired)
        }
    }

    func testDetachedProviderCallsMainActorEntryPoint() async throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let activity = make("background-event", source: pluginSource, priority: .normal, policy: .transient)
        try await Task.detached {
            try await manager.publish(activity)
        }.value
        XCTAssertEqual(manager.current?.id, "background-event")
    }

    func testUnchangedCurrentDoesNotRepublish() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        var notifications = 0
        let observation = manager.$current.dropFirst().sink { _ in notifications += 1 }
        let music = make("music", source: musicSource, priority: .background, policy: .persistent)
        try manager.publish(music)
        XCTAssertEqual(notifications, 1)
        manager.processDeadlines()
        try manager.update(music)
        XCTAssertEqual(notifications, 1)
        withExtendedLifetime(observation) {}
    }

    func testEndedOneOffSourcesReleaseAllSchedulingMetadata() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)

        for index in 0..<100 {
            let source = ActivitySource(kind: .plugin, identifier: "stress.source.\(index)")
            let activity = make(
                "stress.activity.\(index)",
                source: source,
                priority: .normal,
                policy: .transient
            )
            try manager.publish(activity)
            try manager.end(id: activity.id, source: source)
        }

        XCTAssertNil(manager.current)
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertEqual(
            manager.diagnostics,
            ActivityManagerDiagnostics(
                activityCount: 0,
                instanceTokenCount: 0,
                displayDeadlineCount: 0,
                firstPresentedCount: 0,
                rateLimitedSourceCount: 0,
                scheduledWakeDeadline: nil
            )
        )
    }

    private func make(_ id: String, source: ActivitySource, priority: ActivityPriority, policy: ActivityLifecycle.Policy) -> IslandActivity {
        IslandActivity(id: id, source: source, priority: priority, lifecycle: ActivityLifecycle(policy: policy), presentation: ActivityPresentation(title: id), createdAt: start)
    }
}
