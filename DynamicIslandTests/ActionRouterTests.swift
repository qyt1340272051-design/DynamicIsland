import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class ActionRouterTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 40_000)
    private let source = ActivitySource(kind: .builtIn, identifier: "pomodoro")

    func testActionRoutesToOwnerAndUpdateRetainsInstanceToken() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let router = ActionRouter(manager: manager)
        var received: [RoutedActivityAction] = []
        router.register(source: source) { received.append($0) }
        try manager.publish(makeActivity())
        let snapshot = try XCTUnwrap(manager.currentSnapshot)

        XCTAssertEqual(dispatch(router, snapshot, "pomodoro.pause"), .handled)
        XCTAssertEqual(received.map(\.actionID), ["pomodoro.pause"])
        XCTAssertEqual(received[0].activityID, "pomodoro-session")
        XCTAssertEqual(received[0].source, source)

        var updated = makeActivity()
        updated.presentation.title = "Paused"
        try manager.update(updated)
        XCTAssertEqual(manager.currentSnapshot?.instanceToken, snapshot.instanceToken)
        XCTAssertEqual(dispatch(router, snapshot, "pomodoro.resume"), .handled)
        XCTAssertEqual(received.map(\.actionID), ["pomodoro.pause", "pomodoro.resume"])
    }

    func testEndedIDReuseRejectsOldRenderSnapshotEvenWithIdenticalContentAndClock() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let router = ActionRouter(manager: manager)
        var handled = 0
        router.register(source: source) { _ in handled += 1 }
        try manager.publish(makeActivity())
        let old = try XCTUnwrap(manager.currentSnapshot)

        try manager.end(id: old.activity.id, source: source)
        XCTAssertEqual(dispatch(router, old, "pomodoro.pause"), .inactiveActivity)
        try manager.publish(makeActivity())
        let new = try XCTUnwrap(manager.currentSnapshot)
        XCTAssertNotEqual(old.instanceToken, new.instanceToken)
        XCTAssertEqual(old.activity.id, new.activity.id)
        XCTAssertEqual(old.activity.createdAt, new.activity.createdAt)
        XCTAssertEqual(dispatch(router, old, "pomodoro.pause"), .inactiveActivity)
        XCTAssertEqual(dispatch(router, new, "pomodoro.pause"), .handled)
        XCTAssertEqual(handled, 1)
    }

    func testEndedExpiredAndDismissedActivitiesRejectActions() throws {
        let clock = TestActivityClock(start)
        let manager = ActivityManager(clock: clock, configuration: .immediate)
        let router = ActionRouter(manager: manager)
        router.register(source: source) { _ in XCTFail("Inactive activity reached handler") }
        try manager.publish(makeActivity())
        let dismissed = try XCTUnwrap(manager.currentSnapshot)
        try manager.dismiss(id: dismissed.activity.id, source: source)
        XCTAssertEqual(dispatch(router, dismissed, "pomodoro.stop"), .inactiveActivity)
        try manager.end(id: dismissed.activity.id, source: source)

        var expiring = makeActivity()
        expiring.expiresAt = start.addingTimeInterval(1)
        try manager.publish(expiring)
        let expiringSnapshot = try XCTUnwrap(manager.currentSnapshot)
        clock.advance(by: 2)
        XCTAssertEqual(dispatch(router, expiringSnapshot, "pomodoro.stop"), .inactiveActivity)
        XCTAssertNil(manager.activity(id: expiring.id))
    }

    func testDeclaredActionSourceStateAndAuthorizationAreRequired() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let state = RouterPolicyState()
        let router = ActionRouter(
            manager: manager,
            sourceEnabled: { _ in state.sourceIsRunning },
            authorizer: { _, _ in state.allowed }
        )
        var handled = 0
        let registration = router.register(source: source) { _ in handled += 1 }
        try manager.publish(makeActivity())
        let snapshot = try XCTUnwrap(manager.currentSnapshot)

        XCTAssertEqual(dispatch(router, snapshot, "pomodoro.unknown"), .undeclaredAction)
        XCTAssertEqual(dispatch(router, snapshot, "pomodoro.pause"), .unauthorized)
        state.allowed = true
        state.sourceIsRunning = false
        XCTAssertEqual(dispatch(router, snapshot, "pomodoro.pause"), .disabledSource)
        state.sourceIsRunning = true
        router.setEnabled(false, for: source)
        XCTAssertEqual(dispatch(router, snapshot, "pomodoro.pause"), .disabledSource)
        router.setEnabled(true, for: source)
        XCTAssertEqual(dispatch(router, snapshot, "pomodoro.pause"), .handled)
        router.unregister(source: source, registration: registration)
        XCTAssertEqual(dispatch(router, snapshot, "pomodoro.pause"), .missingHandler)
        XCTAssertEqual(handled, 1)
    }

    func testInvalidPayloadAndReentrantHandlerAreSafe() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let router = ActionRouter(manager: manager)
        router.register(source: source) { action in
            if action.actionID == "pomodoro.stop" {
                try? manager.end(id: action.activityID, source: action.source)
            }
        }
        try manager.publish(makeActivity())
        let snapshot = try XCTUnwrap(manager.currentSnapshot)

        XCTAssertEqual(dispatch(router, snapshot, "pomodoro.stop", value: .slider(.nan)), .invalidPayload)
        XCTAssertEqual(dispatch(router, snapshot, "pomodoro.stop", value: .slider(-0.1)), .invalidPayload)
        XCTAssertEqual(dispatch(router, snapshot, "bad action id"), .invalidActionID)
        XCTAssertEqual(dispatch(router, snapshot, String(repeating: "x", count: IslandNode.Limits.maxActionIDBytes + 1)), .invalidActionID)
        XCTAssertEqual(dispatch(router, snapshot, "pomodoro.stop"), .handled)
        XCTAssertNil(manager.activity(id: snapshot.activity.id))
        XCTAssertEqual(dispatch(router, snapshot, "pomodoro.stop"), .inactiveActivity)
    }

    func testPreemptedActivityCannotReceiveRetainedButtonAction() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let router = ActionRouter(manager: manager)
        router.register(source: source) { _ in XCTFail("Background activity reached handler") }
        try manager.publish(makeActivity())
        let old = try XCTUnwrap(manager.currentSnapshot)
        let alert = IslandActivity(
            id: "alert", source: .init(kind: .builtIn, identifier: "alert"),
            priority: .critical, lifecycle: ActivityLifecycle(policy: .critical),
            presentation: ActivityPresentation(title: "Alert"), createdAt: start
        )
        try manager.publish(alert)
        XCTAssertEqual(manager.activity(id: old.activity.id)?.lifecycle.state, .background)
        XCTAssertEqual(dispatch(router, old, "pomodoro.pause"), .inactiveActivity)
    }

    func testPluginSourceIsRejectedAfterDisableEvenWhileActivityIsVisible() throws {
        let pluginSource = ActivitySource(kind: .plugin, identifier: "example.pomodoro")
        let state = RouterPolicyState()
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let router = ActionRouter(manager: manager, sourceEnabled: { _ in state.sourceIsRunning })
        var handled = 0
        router.register(source: pluginSource) { _ in handled += 1 }
        try manager.publish(makeActivity(for: pluginSource))
        let snapshot = try XCTUnwrap(manager.currentSnapshot)

        state.sourceIsRunning = false
        XCTAssertEqual(dispatch(router, snapshot, "pomodoro.pause"), .disabledSource)
        XCTAssertEqual(handled, 0)
    }

    private func dispatch(
        _ router: ActionRouter,
        _ snapshot: ActivitySnapshot,
        _ actionID: String,
        value: IslandRenderActionValue = .none
    ) -> ActionDispatchResult {
        router.dispatch(
            id: snapshot.activity.id,
            source: snapshot.activity.source,
            instanceToken: snapshot.instanceToken,
            action: IslandRenderAction(actionID: actionID, value: value)
        )
    }

    private func makeActivity(for owner: ActivitySource? = nil) -> IslandActivity {
        IslandActivity(
            id: "pomodoro-session", source: owner ?? source, priority: .normal,
            lifecycle: ActivityLifecycle(policy: .persistent),
            presentation: ActivityPresentation(title: "Pomodoro"), createdAt: start,
            actions: [
                .init(id: "pomodoro.pause", title: "Pause"),
                .init(id: "pomodoro.resume", title: "Resume"),
                .init(id: "pomodoro.stop", title: "Stop")
            ]
        )
    }
}

@MainActor
private final class RouterPolicyState {
    var allowed = false
    var sourceIsRunning = true
}
