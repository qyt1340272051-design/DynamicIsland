import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class ActivityToolSelectionTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 35_000)
    private let toolSource = ActivitySource(kind: .plugin, identifier: "example.tools")
    private let statusSource = ActivitySource(kind: .builtIn, identifier: "status")

    func testUnselectedToolsNeverEnterAutomaticQueueRegardlessOfPriorityOrCompactVisibility() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        try manager.publish(tool("hidden", priority: .critical, showsCompact: false))
        try manager.publish(tool("visible", priority: .normal, policy: .progress, showsCompact: true))
        XCTAssertNil(manager.current)
        XCTAssertEqual(manager.toolSnapshots.map(\.activity.id), ["hidden", "visible"])

        try manager.publish(status("music", priority: .background))
        XCTAssertEqual(manager.current?.id, "music")
        XCTAssertNil(manager.selectedToolSnapshot)
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
    }

    func testPausedMusicRemainsPersistentAndRestoresItsOriginalInstanceAfterSelectionClears() async throws {
        let service = MusicActivityTestService(info: NowPlayingInfo(
            isPlaying: false, title: "Paused", artist: "Artist", album: "Album", trackIdentifier: "paused-track"
        ))
        let model = makeMusicActivityTestModel(music: service)
        await model.refreshNowPlaying()
        let manager = ActivityManager(clock: TestActivityClock(start))
        let provider = MusicActivityProvider(viewModel: model, manager: manager)
        let music = try XCTUnwrap(manager.currentSnapshot)
        XCTAssertFalse(music.activity.presentation.isCompactVisible)
        XCTAssertEqual(music.activity.lifecycle.policy, .persistent)

        try manager.publish(tool("idle", showsCompact: false))
        XCTAssertEqual(manager.currentSnapshot, music)
        XCTAssertTrue(manager.selectTool(try snapshot("idle", in: manager)))
        XCTAssertEqual(manager.current?.id, "idle")
        manager.clearToolSelection()
        XCTAssertEqual(manager.currentSnapshot, music)
        XCTAssertFalse(manager.currentSnapshot?.activity.presentation.isCompactVisible ?? true)
        XCTAssertNil(manager.selectedToolSnapshot)
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
        withExtendedLifetime(provider) {}
    }

    func testExplicitSelectionWinsCurrentBackgroundTieAndOrdinaryPersistentStatus() throws {
        for priority in [ActivityPriority.background, .normal] {
            let manager = ActivityManager(clock: TestActivityClock(start))
            try manager.publish(status("held", priority: priority))
            let held = try XCTUnwrap(manager.currentSnapshot)
            try manager.publish(tool("first"))
            try manager.publish(tool("second"))
            XCTAssertEqual(manager.currentSnapshot, held)

            XCTAssertTrue(manager.selectTool(try snapshot("first", in: manager)))
            XCTAssertEqual(manager.current?.id, "first")
            XCTAssertTrue(manager.selectTool(try snapshot("second", in: manager)))
            XCTAssertEqual(manager.current?.id, "second")
            XCTAssertEqual(manager.activity(id: "first")?.lifecycle.state, .background)
            XCTAssertEqual(manager.selectedToolSnapshot?.activity.id, "second")
        }
    }

    func testNestedEventPreemptionRetainsSelectionAndRestoresExactToolInstance() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        try manager.publish(status("music", priority: .background))
        try manager.publish(tool("chosen"))
        XCTAssertTrue(manager.selectTool(try snapshot("chosen", in: manager)))
        let chosen = try XCTUnwrap(manager.currentSnapshot)

        try manager.publish(status("transient", policy: .transient))
        try manager.publish(status("important", priority: .important, policy: .transient))
        try manager.publish(status("critical", priority: .critical, policy: .critical))
        XCTAssertEqual(manager.current?.id, "critical")
        XCTAssertEqual(manager.selectedToolSnapshot?.instanceToken, chosen.instanceToken)
        XCTAssertEqual(manager.selectedToolSnapshot?.activity.lifecycle.state, .background)

        try manager.end(id: "critical", source: statusSource)
        XCTAssertEqual(manager.current?.id, "important")
        try manager.end(id: "important", source: statusSource)
        XCTAssertEqual(manager.current?.id, "transient")
        try manager.end(id: "transient", source: statusSource)
        XCTAssertEqual(manager.currentSnapshot, chosen)
    }

    func testSelectionDuringNormalPriorityNoninterruptibleCurrentWaitsForItToEnd() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        try manager.publish(status("guard", priority: .normal, policy: .critical))
        try manager.publish(tool("chosen"))
        XCTAssertTrue(manager.selectTool(try snapshot("chosen", in: manager)))
        XCTAssertEqual(manager.current?.id, "guard")
        XCTAssertEqual(manager.selectedToolSnapshot?.activity.id, "chosen")
        try manager.publish(status("higher", priority: .critical, policy: .transient))
        XCTAssertEqual(manager.current?.id, "guard")

        try manager.end(id: "guard", source: statusSource)
        XCTAssertEqual(manager.current?.id, "higher")
        try manager.end(id: "higher", source: statusSource)
        XCTAssertEqual(manager.current?.id, "chosen")
    }

    func testSelectingDuringInterruptingStatusChangesOnlyTheDeferredChoice() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        try manager.publish(tool("first"))
        try manager.publish(tool("second"))
        XCTAssertTrue(manager.selectTool(try snapshot("first", in: manager)))
        try manager.publish(status("event", policy: .transient))
        XCTAssertTrue(manager.selectTool(try snapshot("second", in: manager)))
        XCTAssertEqual(manager.current?.id, "event")
        XCTAssertEqual(manager.selectedToolSnapshot?.activity.id, "second")
        try manager.end(id: "event", source: statusSource)
        XCTAssertEqual(manager.current?.id, "second")
    }

    func testUpdatesRefreshSelectedPayloadAndOldPayloadCanSelectOnlyTheSameInstance() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        try manager.publish(tool("chosen"))
        let oldPayload = try snapshot("chosen", in: manager)
        XCTAssertTrue(manager.selectTool(oldPayload))
        try manager.publish(status("event", policy: .transient))
        var update = tool("chosen", policy: .persistent, showsCompact: true)
        update.presentation.title = "Updated"
        try manager.update(update)
        XCTAssertEqual(manager.selectedToolSnapshot?.activity.presentation.title, "Updated")
        XCTAssertEqual(manager.selectedToolSnapshot?.instanceToken, oldPayload.instanceToken)
        XCTAssertTrue(manager.selectTool(oldPayload))
        XCTAssertEqual(manager.selectedToolSnapshot?.activity.presentation.title, "Updated")
        XCTAssertEqual(manager.current?.id, "event")
        try manager.end(id: "event", source: statusSource)
        XCTAssertEqual(manager.current?.presentation.title, "Updated")
        XCTAssertTrue(manager.current?.presentation.isCompactVisible ?? false)
    }

    func testStaleTokenWrongSourceAndStatusInputsCannotReplaceAValidChoice() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        try manager.publish(status("music", priority: .background))
        let music = try XCTUnwrap(manager.currentSnapshot)
        try manager.publish(tool("old"))
        let old = try snapshot("old", in: manager)
        try manager.end(id: "old", source: toolSource)
        try manager.publish(tool("old"))
        try manager.publish(tool("chosen"))
        XCTAssertTrue(manager.selectTool(try snapshot("chosen", in: manager)))
        let chosen = try XCTUnwrap(manager.selectedToolSnapshot)
        let replacement = try snapshot("old", in: manager)
        XCTAssertNotEqual(replacement.instanceToken, old.instanceToken)
        XCTAssertFalse(manager.selectTool(old))
        XCTAssertFalse(manager.selectTool(music))
        let wrongSource = ActivitySnapshot(
            activity: tool("old", source: .init(kind: .plugin, identifier: "another.plugin")),
            instanceToken: replacement.instanceToken
        )
        XCTAssertFalse(manager.selectTool(wrongSource))
        XCTAssertEqual(manager.selectedToolSnapshot, chosen)
        XCTAssertEqual(manager.currentSnapshot, chosen)
    }

    func testCoreRejectsInvalidToolPoliciesBeforeMutation() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        try manager.publish(tool("chosen"))
        XCTAssertTrue(manager.selectTool(try snapshot("chosen", in: manager)))
        let original = try XCTUnwrap(manager.currentSnapshot)
        for policy in [ActivityLifecycle.Policy.transient, .critical] {
            XCTAssertThrowsError(try manager.publish(tool("invalid", policy: policy))) {
                XCTAssertEqual($0 as? ActivityManagerError, .invalidToolPolicy)
            }
        }
        var invalid = status("chosen", source: toolSource, policy: .persistent)
        invalid.lifecycle = .init(policy: .critical)
        invalid.presentation.role = .tool
        XCTAssertThrowsError(try manager.update(invalid)) {
            XCTAssertEqual($0 as? ActivityManagerError, .invalidToolPolicy)
        }
        XCTAssertEqual(manager.currentSnapshot, original)
        XCTAssertEqual(manager.selectedToolSnapshot, original)
        XCTAssertEqual(manager.toolSnapshots.count, 1)
        XCTAssertNil(manager.activity(id: "invalid"))
    }

    func testEndingSelectedToolDoesNotBindAReplacementWithTheSameID() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        try manager.publish(status("music", priority: .background))
        try manager.publish(tool("chosen"))
        let old = try snapshot("chosen", in: manager)
        XCTAssertTrue(manager.selectTool(old))
        try manager.end(id: "chosen", source: toolSource)
        XCTAssertNil(manager.selectedToolSnapshot)
        XCTAssertEqual(manager.current?.id, "music")
        try manager.publish(tool("chosen"))
        XCTAssertEqual(manager.current?.id, "music")
        XCTAssertFalse(manager.selectTool(old))
        let replacement = try snapshot("chosen", in: manager)
        XCTAssertNotEqual(old.instanceToken, replacement.instanceToken)
        XCTAssertTrue(manager.selectTool(replacement))
    }

    func testDismissedAndExpiredToolsLeaveTheCatalogueAndCannotBeSelectedAgain() throws {
        let clock = TestActivityClock(start)
        let manager = ActivityManager(clock: clock, configuration: .immediate)
        try manager.publish(tool("dismissed"))
        let dismissed = try snapshot("dismissed", in: manager)
        XCTAssertTrue(manager.selectTool(dismissed))
        try manager.dismiss(id: "dismissed", source: toolSource)
        XCTAssertNil(manager.selectedToolSnapshot)
        XCTAssertNil(manager.current)
        XCTAssertFalse(manager.selectTool(dismissed))

        var expiring = tool("expired")
        expiring.expiresAt = start.addingTimeInterval(1)
        try manager.publish(expiring)
        let expired = try snapshot("expired", in: manager)
        XCTAssertTrue(manager.selectTool(expired))
        clock.advance(by: 1)
        manager.processDeadlines()
        XCTAssertNil(manager.current)
        XCTAssertNil(manager.selectedToolSnapshot)
        XCTAssertTrue(manager.toolSnapshots.isEmpty)
        XCTAssertFalse(manager.selectTool(expired))
    }

    func testDisableClearsSelectionBeforeSourceCleanupAndEnableDoesNotRestoreIt() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        manager.requirePluginActivation()
        manager.setPluginSourceEnabled(true, for: toolSource)
        try manager.publish(status("music", priority: .background))
        try manager.publish(tool("chosen"))
        let old = try snapshot("chosen", in: manager)
        XCTAssertTrue(manager.selectTool(old))
        manager.setPluginSourceEnabled(false, for: toolSource)
        XCTAssertNil(manager.selectedToolSnapshot)
        XCTAssertTrue(manager.toolSnapshots.isEmpty)
        XCTAssertEqual(manager.current?.id, "music")
        XCTAssertFalse(manager.selectTool(old))
        manager.endAll(source: toolSource)
        manager.setPluginSourceEnabled(true, for: toolSource)
        try manager.publish(tool("chosen"))
        XCTAssertNil(manager.selectedToolSnapshot)
        XCTAssertFalse(manager.selectTool(old))
        XCTAssertEqual(manager.current?.id, "music")
    }

    func testChangingRoleClearsSelectionAndChangingBackRequiresAnotherUserChoice() throws {
        let manager = ActivityManager(clock: TestActivityClock(start))
        try manager.publish(status("music", priority: .background))
        try manager.publish(tool("chosen"))
        let original = try snapshot("chosen", in: manager)
        XCTAssertTrue(manager.selectTool(original))
        var ordinary = tool("chosen")
        ordinary.presentation.role = .status
        try manager.update(ordinary)
        XCTAssertNil(manager.selectedToolSnapshot)
        XCTAssertTrue(manager.toolSnapshots.isEmpty)
        XCTAssertFalse(manager.selectTool(original))
        try manager.update(tool("chosen"))
        XCTAssertNil(manager.selectedToolSnapshot)
        XCTAssertEqual(manager.current?.id, "music")
        XCTAssertEqual(manager.toolSnapshots.first?.instanceToken, original.instanceToken)
    }

    func testClearingTheOnlyToolImmediatelyBackgroundsItAndLeavesNoWake() throws {
        let manager = ActivityManager(clock: TestActivityClock(start))
        try manager.publish(tool("chosen"))
        XCTAssertTrue(manager.selectTool(try snapshot("chosen", in: manager)))
        manager.clearToolSelection()
        XCTAssertNil(manager.current)
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertNil(manager.selectedToolSnapshot)
        XCTAssertEqual(manager.activity(id: "chosen")?.lifecycle.state, .background)
        XCTAssertEqual(manager.toolSnapshots.first?.activity.lifecycle.state, .background)
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
        manager.processDeadlines()
        XCTAssertNil(manager.current)
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
    }

    func testRetainedActionsAreAdmittedOnlyForTheCurrentSelectedInstance() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let router = ActionRouter(manager: manager)
        var handled: [String] = []
        router.register(source: toolSource) { handled.append($0.activityID) }
        try manager.publish(tool("first"))
        try manager.publish(tool("second"))
        let first = try snapshot("first", in: manager)
        let second = try snapshot("second", in: manager)
        XCTAssertEqual(dispatch(router, first), .inactiveActivity)
        XCTAssertTrue(manager.selectTool(first))
        XCTAssertEqual(dispatch(router, first), .handled)
        XCTAssertTrue(manager.selectTool(second))
        XCTAssertEqual(dispatch(router, first), .inactiveActivity)
        XCTAssertEqual(dispatch(router, second), .handled)
        try manager.publish(status("event", priority: .important, policy: .transient))
        XCTAssertEqual(dispatch(router, second), .inactiveActivity)
        try manager.end(id: "event", source: statusSource)
        XCTAssertEqual(dispatch(router, second), .handled)
        manager.clearToolSelection()
        XCTAssertEqual(dispatch(router, second), .inactiveActivity)
        XCTAssertEqual(handled, ["first", "second", "second"])
    }

    func testExplicitChoiceBypassesToolRateAndDwellButAutomaticRestoreHonoursRate() throws {
        let clock = TestActivityClock(start)
        let configuration = ActivityScheduler.Configuration(
            ordinaryDebounce: 0, minimumDwell: 0.5, minimumIntervalBySource: [toolSource: 10]
        )
        let manager = ActivityManager(clock: clock, configuration: configuration)
        try manager.publish(status("music", priority: .background))
        try manager.publish(tool("chosen"))
        let chosen = try snapshot("chosen", in: manager)
        XCTAssertTrue(manager.selectTool(chosen))
        manager.clearToolSelection()
        XCTAssertEqual(manager.current?.id, "music")
        XCTAssertTrue(manager.selectTool(chosen))
        XCTAssertEqual(manager.current?.id, "chosen")
        try manager.publish(status("event", policy: .transient))
        XCTAssertEqual(manager.current?.id, "chosen")
        clock.advance(by: 0.5)
        manager.processDeadlines()
        XCTAssertEqual(manager.current?.id, "event")
        try manager.end(id: "event", source: statusSource)
        XCTAssertEqual(manager.current?.id, "music")
        XCTAssertEqual(manager.selectedToolSnapshot?.instanceToken, chosen.instanceToken)
        XCTAssertEqual(manager.diagnostics.scheduledWakeDeadline, start.addingTimeInterval(10))
        clock.advance(by: 9.5)
        manager.processDeadlines()
        XCTAssertEqual(manager.current?.id, "chosen")
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
    }

    func testRateLimitedEventRetainsItsWakeWhileSelectedToolIsCurrent() throws {
        let clock = TestActivityClock(start)
        let configuration = ActivityScheduler.Configuration(
            ordinaryDebounce: 0, minimumDwell: 0, minimumIntervalBySource: [statusSource: 2]
        )
        let manager = ActivityManager(clock: clock, configuration: configuration)
        try manager.publish(tool("chosen"))
        XCTAssertTrue(manager.selectTool(try snapshot("chosen", in: manager)))
        try manager.publish(status("first", policy: .transient))
        try manager.end(id: "first", source: statusSource)
        XCTAssertEqual(manager.current?.id, "chosen")
        try manager.publish(status("second", policy: .transient))
        XCTAssertEqual(manager.current?.id, "chosen")
        XCTAssertEqual(manager.diagnostics.scheduledWakeDeadline, start.addingTimeInterval(2))
        clock.advance(by: 2)
        manager.processDeadlines()
        XCTAssertEqual(manager.current?.id, "second")
        XCTAssertEqual(manager.selectedToolSnapshot?.activity.id, "chosen")
    }

    private func snapshot(_ id: String, in manager: ActivityManager) throws -> ActivitySnapshot {
        try XCTUnwrap(manager.toolSnapshots.first { $0.activity.id == id })
    }

    private func tool(
        _ id: String, source: ActivitySource? = nil, priority: ActivityPriority = .background,
        policy: ActivityLifecycle.Policy = .persistent, showsCompact: Bool = false
    ) -> IslandActivity {
        var presentation = ActivityPresentation(title: id, showsCompact: showsCompact)
        presentation.role = .tool
        return IslandActivity(
            id: id, source: source ?? toolSource, priority: priority, lifecycle: .init(policy: policy),
            presentation: presentation, createdAt: start, actions: [.init(id: "run", title: "Run")]
        )
    }

    private func status(
        _ id: String, source: ActivitySource? = nil, priority: ActivityPriority = .normal,
        policy: ActivityLifecycle.Policy = .persistent
    ) -> IslandActivity {
        IslandActivity(
            id: id, source: source ?? statusSource, priority: priority, lifecycle: .init(policy: policy),
            presentation: .init(title: id), createdAt: start
        )
    }

    private func dispatch(_ router: ActionRouter, _ snapshot: ActivitySnapshot) -> ActionDispatchResult {
        router.dispatch(
            id: snapshot.activity.id, source: snapshot.activity.source, instanceToken: snapshot.instanceToken,
            action: .init(actionID: "run", value: .none)
        )
    }
}
