import Combine
import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class ActivityAutomaticCompactTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 36_000)
    private let toolSource = ActivitySource(kind: .plugin, identifier: "example.automatic-tools")
    private let statusSource = ActivitySource(kind: .builtIn, identifier: "automatic-status")

    func testExpandedDefaultAndLegacyVisibleToolsRemainSelectionOnly() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        try manager.publish(status("music", priority: .background))
        let music = try XCTUnwrap(manager.currentSnapshot)
        try manager.publish(tool("automatic"))
        try manager.publish(tool("legacy", compactPolicy: nil))
        try manager.publish(tool("selected-only", compactPolicy: .selectedOnly))
        try manager.publish(tool("hidden", showsCompact: false))
        XCTAssertEqual(manager.currentSnapshot, music)
        XCTAssertEqual(manager.toolSnapshots.count, 4)

        manager.setPresentationContext(.compact)
        XCTAssertEqual(manager.current?.id, "automatic")
        XCTAssertNil(manager.selectedToolSnapshot)
        XCTAssertFalse(manager.selectTool(try snapshot("legacy", in: manager)))
        try manager.end(id: "automatic", source: toolSource)
        XCTAssertEqual(manager.currentSnapshot, music)
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
        manager.setPresentationContext(.expanded)
        XCTAssertTrue(manager.selectTool(try snapshot("legacy", in: manager)))
        XCTAssertEqual(manager.current?.id, "legacy")
    }

    func testAutomaticToolReplacesRealPlayingAndPausedMusicAndRestoresTheirInstances() async throws {
        for playing in [true, false] {
            let service = MusicActivityTestService(info: NowPlayingInfo(
                isPlaying: playing, title: "Track", artist: "Artist", album: "Album",
                duration: 120, position: 10, trackIdentifier: "automatic-track"
            ))
            let model = makeMusicActivityTestModel(music: service)
            await model.refreshNowPlaying()
            let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
            let provider = MusicActivityProvider(viewModel: model, manager: manager)
            let music = try XCTUnwrap(manager.currentSnapshot)
            XCTAssertEqual(music.activity.priority, .background)
            XCTAssertEqual(music.activity.presentation.isCompactVisible, playing)
            try manager.publish(tool("focus"))
            XCTAssertEqual(manager.currentSnapshot, music)

            manager.setPresentationContext(.compact)
            let focus = try XCTUnwrap(manager.currentSnapshot)
            XCTAssertEqual(focus.activity.id, "focus")
            XCTAssertEqual(manager.activity(id: music.activity.id)?.lifecycle.state, .background)
            manager.setPresentationContext(.expanded)
            XCTAssertEqual(manager.currentSnapshot, music)
            XCTAssertTrue(manager.selectTool(focus))
            XCTAssertEqual(manager.currentSnapshot?.instanceToken, focus.instanceToken)
            manager.clearToolSelection()
            XCTAssertEqual(manager.currentSnapshot, music)
            withExtendedLifetime(provider) {}
        }
    }

    func testAutomaticToolWinsOrdinaryNormalPersistentStatusWithoutRaisingItsPriority() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        try manager.publish(status("ordinary", priority: .normal))
        try manager.publish(tool("focus", policy: .progress))
        manager.setPresentationContext(.compact)
        XCTAssertEqual(manager.current?.id, "focus")
        XCTAssertEqual(manager.current?.priority, .background)
        XCTAssertNil(manager.selectedToolSnapshot)
        manager.setPresentationContext(.expanded)
        XCTAssertEqual(manager.current?.id, "ordinary")
    }

    func testVolumeAndBatteryEventsPreemptAndRestoreTheExactAutomaticTool() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        manager.setPresentationContext(.compact)
        try manager.publish(tool("focus"))
        let focus = try XCTUnwrap(manager.currentSnapshot)
        try manager.publish(status("volume", priority: .normal, policy: .transient))
        XCTAssertEqual(manager.current?.id, "volume")
        try manager.publish(status("charging", priority: .important, policy: .transient))
        XCTAssertEqual(manager.current?.id, "charging")
        try manager.publish(status("critical-battery", priority: .critical, policy: .critical))
        XCTAssertEqual(manager.current?.id, "critical-battery")
        XCTAssertNil(manager.selectedToolSnapshot)
        try manager.end(id: "critical-battery", source: statusSource)
        XCTAssertEqual(manager.current?.id, "charging")
        try manager.end(id: "charging", source: statusSource)
        XCTAssertEqual(manager.current?.id, "volume")
        try manager.end(id: "volume", source: statusSource)
        XCTAssertEqual(manager.currentSnapshot, focus)
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
    }

    func testNormalPriorityNoninterruptibleCurrentStillHoldsAgainstAutomaticTool() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        try manager.publish(status("held", priority: .normal, policy: .critical))
        try manager.publish(tool("focus"))
        manager.setPresentationContext(.compact)
        XCTAssertEqual(manager.current?.id, "held")
        try manager.publish(status("urgent", priority: .critical, policy: .transient))
        XCTAssertEqual(manager.current?.id, "held")
        try manager.end(id: "held", source: statusSource)
        XCTAssertEqual(manager.current?.id, "urgent")
        try manager.end(id: "urgent", source: statusSource)
        XCTAssertEqual(manager.current?.id, "focus")
    }

    func testFoldClearsSelectionAndChoosesAutomaticToolInOneReconciliation() throws {
        let config = ActivityScheduler.Configuration(ordinaryDebounce: 0, minimumDwell: 100)
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: config)
        try manager.publish(status("music", priority: .background))
        try manager.publish(tool("manual", compactPolicy: nil))
        try manager.publish(tool("automatic"))
        XCTAssertTrue(manager.selectTool(try snapshot("manual", in: manager)))
        var presented: [String?] = []
        let observation = manager.$currentSnapshot.dropFirst().sink { presented.append($0?.activity.id) }

        manager.setPresentationContext(.compact)
        XCTAssertEqual(presented, ["automatic"], "Folding must not briefly select music or retain the old tool's dwell.")
        XCTAssertNil(manager.selectedToolSnapshot)
        XCTAssertEqual(manager.activity(id: "manual")?.lifecycle.state, .background)
        manager.clearToolSelection()
        XCTAssertEqual(manager.current?.id, "automatic", "Clearing a menu choice does not revoke explicit compact opt-in.")
        manager.setPresentationContext(.expanded)
        XCTAssertEqual(manager.current?.id, "music", "An ineligible automatic tool cannot be retained by dwell.")
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
        withExtendedLifetime(observation) {}
    }

    func testLeavingCompactWithNoFallbackBackgroundsToolAndCancelsItsWake() throws {
        let manager = ActivityManager(clock: TestActivityClock(start))
        manager.setPresentationContext(.compact)
        try manager.publish(tool("focus"))
        let focus = try XCTUnwrap(manager.currentSnapshot)
        manager.setPresentationContext(.expanded)
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertEqual(manager.activity(id: "focus")?.lifecycle.state, .background)
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
        manager.processDeadlines()
        XCTAssertNil(manager.current)
        XCTAssertTrue(manager.selectTool(focus), "Changing mode alone must not rotate the Activity instance token.")
        manager.setPresentationContext(.compact)
        XCTAssertEqual(manager.currentSnapshot?.instanceToken, focus.instanceToken)
        XCTAssertNil(manager.selectedToolSnapshot)
    }

    func testRouterAdmitsOnlyCurrentInstanceAcrossModeChangesAndSameIDReplacement() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let router = ActionRouter(manager: manager)
        var handled = 0
        router.register(source: toolSource) { _ in handled += 1 }
        try manager.publish(tool("focus"))
        try manager.publish(tool("inventory", compactPolicy: nil))
        let inventory = try snapshot("inventory", in: manager)
        let original = try snapshot("focus", in: manager)
        XCTAssertEqual(dispatch(router, original), .inactiveActivity)
        manager.setPresentationContext(.compact)
        XCTAssertEqual(dispatch(router, inventory), .inactiveActivity)
        XCTAssertEqual(dispatch(router, original), .handled)
        manager.setPresentationContext(.expanded)
        XCTAssertEqual(dispatch(router, original), .inactiveActivity)
        XCTAssertTrue(manager.selectTool(original))
        XCTAssertEqual(dispatch(router, original), .handled)
        manager.setPresentationContext(.compact)
        XCTAssertFalse(manager.selectTool(inventory))
        XCTAssertEqual(dispatch(router, original), .handled)
        try manager.end(id: "focus", source: toolSource)
        try manager.publish(tool("focus"))
        let replacement = try XCTUnwrap(manager.currentSnapshot)
        XCTAssertNotEqual(replacement.instanceToken, original.instanceToken)
        XCTAssertEqual(dispatch(router, original), .inactiveActivity)
        XCTAssertEqual(dispatch(router, replacement), .handled)
        manager.setPresentationContext(.expanded)
        XCTAssertFalse(manager.selectTool(original))
        XCTAssertTrue(manager.selectTool(replacement))
        XCTAssertEqual(handled, 4)
    }

    func testPolicyVisibilityAndRoleUpdatesRecomputeAutomaticEligibility() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        try manager.publish(status("ordinary", priority: .normal))
        manager.setPresentationContext(.compact)
        try manager.publish(tool("focus"))
        let original = try XCTUnwrap(manager.currentSnapshot)
        try manager.update(tool("focus", compactPolicy: .selectedOnly))
        XCTAssertEqual(manager.current?.id, "ordinary")
        try manager.update(tool("focus", showsCompact: false))
        XCTAssertEqual(manager.current?.id, "ordinary")
        try manager.update(tool("focus"))
        XCTAssertEqual(manager.currentSnapshot?.instanceToken, original.instanceToken)

        var ordinary = tool("focus", compactPolicy: nil)
        ordinary.presentation.role = .status
        try manager.update(ordinary)
        XCTAssertTrue(manager.toolSnapshots.isEmpty)
        XCTAssertNil(manager.selectedToolSnapshot)
        XCTAssertEqual(manager.current?.id, "ordinary")
        try manager.update(tool("focus", compactPolicy: nil))
        XCTAssertEqual(manager.current?.id, "ordinary")
        try manager.update(tool("focus"))
        XCTAssertEqual(manager.currentSnapshot?.instanceToken, original.instanceToken)
    }

    func testAnyExplicitCompactPolicyOnStatusIsRejectedBeforePublishOrUpdate() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        for policy in [ActivityPresentation.CompactPolicy.automatic, .selectedOnly] {
            var invalid = status("invalid", priority: .normal)
            invalid.presentation.compactPolicy = policy
            XCTAssertThrowsError(try manager.publish(invalid)) {
                XCTAssertEqual($0 as? ActivityManagerError, .invalidToolPolicy)
            }
            XCTAssertNil(manager.activity(id: invalid.id))
        }
        manager.setPresentationContext(.compact)
        try manager.publish(tool("focus"))
        let current = try XCTUnwrap(manager.currentSnapshot)
        for policy in [ActivityPresentation.CompactPolicy.automatic, .selectedOnly] {
            var update = tool("focus", compactPolicy: policy)
            update.presentation.role = .status
            XCTAssertThrowsError(try manager.update(update)) {
                XCTAssertEqual($0 as? ActivityManagerError, .invalidToolPolicy)
            }
            XCTAssertEqual(manager.currentSnapshot, current)
        }
        XCTAssertEqual(manager.toolSnapshots.count, 1)
    }

    func testDisableImmediatelyClosesAutomaticEligibilityAndReplacementRejectsOldToken() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        manager.requirePluginActivation()
        manager.setPluginSourceEnabled(true, for: toolSource)
        try manager.publish(status("music", priority: .background))
        manager.setPresentationContext(.compact)
        try manager.publish(tool("focus"))
        let old = try XCTUnwrap(manager.currentSnapshot)
        manager.setPluginSourceEnabled(false, for: toolSource)
        XCTAssertEqual(manager.current?.id, "music")
        XCTAssertTrue(manager.toolSnapshots.isEmpty)
        XCTAssertNil(manager.selectedToolSnapshot)
        manager.endAll(source: toolSource)
        manager.setPluginSourceEnabled(true, for: toolSource)
        try manager.publish(tool("focus"))
        let replacement = try XCTUnwrap(manager.currentSnapshot)
        XCTAssertNotEqual(replacement.instanceToken, old.instanceToken)
        manager.setPresentationContext(.expanded)
        XCTAssertFalse(manager.selectTool(old))
        XCTAssertTrue(manager.selectTool(replacement))
    }

    func testDismissAndAbsoluteExpiryRemoveAutomaticCandidatesWithoutPeriodicWake() throws {
        let clock = TestActivityClock(start)
        let manager = ActivityManager(clock: clock, configuration: .immediate)
        manager.setPresentationContext(.compact)
        try manager.publish(tool("dismissed"))
        try manager.dismiss(id: "dismissed", source: toolSource)
        XCTAssertNil(manager.current)
        XCTAssertTrue(manager.toolSnapshots.isEmpty)
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
        var expiring = tool("expiring")
        expiring.expiresAt = start.addingTimeInterval(2)
        try manager.publish(expiring)
        let expired = try XCTUnwrap(manager.currentSnapshot)
        XCTAssertEqual(manager.diagnostics.scheduledWakeDeadline, expiring.expiresAt)
        clock.advance(by: 2)
        manager.processDeadlines()
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertNil(manager.activity(id: "expiring"))
        XCTAssertTrue(manager.toolSnapshots.isEmpty)
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
        manager.setPresentationContext(.expanded)
        XCTAssertFalse(manager.selectTool(expired))
    }

    func testAutomaticPresentationHonoursDwellAndSourceRateOnRestore() throws {
        let clock = TestActivityClock(start)
        let config = ActivityScheduler.Configuration(
            ordinaryDebounce: 0, minimumDwell: 1, minimumIntervalBySource: [toolSource: 10]
        )
        let manager = ActivityManager(clock: clock, configuration: config)
        manager.setPresentationContext(.compact)
        try manager.publish(status("music", priority: .background))
        try manager.publish(tool("focus"))
        XCTAssertEqual(manager.current?.id, "music")
        XCTAssertEqual(manager.diagnostics.scheduledWakeDeadline, start.addingTimeInterval(1))
        clock.advance(by: 1)
        manager.processDeadlines()
        XCTAssertEqual(manager.current?.id, "focus")
        try manager.publish(status("event", priority: .important, policy: .transient))
        XCTAssertEqual(manager.current?.id, "event")
        try manager.end(id: "event", source: statusSource)
        XCTAssertEqual(manager.current?.id, "music")
        XCTAssertEqual(manager.diagnostics.scheduledWakeDeadline, start.addingTimeInterval(11))
        clock.advance(by: 9)
        manager.processDeadlines()
        XCTAssertEqual(manager.current?.id, "music")
        clock.advance(by: 1)
        manager.processDeadlines()
        XCTAssertEqual(manager.current?.id, "focus")
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
    }

    func testExpandedCancelsPendingAutomaticDebounceWithoutPresentingHiddenTool() throws {
        let clock = TestActivityClock(start)
        let config = ActivityScheduler.Configuration(ordinaryDebounce: 2, minimumDwell: 0)
        let manager = ActivityManager(clock: clock, configuration: config)
        try manager.publish(status("music", priority: .background))
        manager.setPresentationContext(.compact)
        try manager.publish(tool("focus"))
        XCTAssertEqual(manager.current?.id, "music")
        XCTAssertEqual(manager.diagnostics.scheduledWakeDeadline, start.addingTimeInterval(2))
        manager.setPresentationContext(.expanded)
        XCTAssertEqual(manager.current?.id, "music")
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
        clock.advance(by: 2)
        manager.processDeadlines()
        XCTAssertEqual(manager.current?.id, "music")
        manager.setPresentationContext(.compact)
        XCTAssertEqual(manager.current?.id, "music")
        XCTAssertEqual(manager.diagnostics.scheduledWakeDeadline, start.addingTimeInterval(4))
        clock.advance(by: 2)
        manager.processDeadlines()
        XCTAssertEqual(manager.current?.id, "focus")
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
    }

    func testExplicitExpandedChoiceStillBypassesItsOwnRateAndDwell() throws {
        let clock = TestActivityClock(start)
        let config = ActivityScheduler.Configuration(
            ordinaryDebounce: 0, minimumDwell: 10, minimumIntervalBySource: [toolSource: 60]
        )
        let manager = ActivityManager(clock: clock, configuration: config)
        manager.setPresentationContext(.compact)
        try manager.publish(tool("focus"))
        let focus = try XCTUnwrap(manager.currentSnapshot)
        try manager.publish(status("event", priority: .important, policy: .transient))
        try manager.end(id: "event", source: statusSource)
        XCTAssertNil(manager.current)
        try manager.publish(status("music", priority: .background))
        manager.setPresentationContext(.expanded)
        XCTAssertEqual(manager.current?.id, "music")
        XCTAssertTrue(manager.selectTool(focus))
        XCTAssertEqual(manager.current?.id, "focus")
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
    }

    func testRateLimitedTransientKeepsItsWakeWhileAutomaticToolRemainsCurrent() throws {
        let clock = TestActivityClock(start)
        let config = ActivityScheduler.Configuration(
            ordinaryDebounce: 0, minimumDwell: 0, minimumIntervalBySource: [statusSource: 2]
        )
        let manager = ActivityManager(clock: clock, configuration: config)
        manager.setPresentationContext(.compact)
        try manager.publish(tool("focus"))
        try manager.publish(status("first", priority: .normal, policy: .transient))
        try manager.end(id: "first", source: statusSource)
        try manager.publish(status("second", priority: .normal, policy: .transient))
        XCTAssertEqual(manager.current?.id, "focus")
        XCTAssertEqual(manager.diagnostics.scheduledWakeDeadline, start.addingTimeInterval(2))
        clock.advance(by: 2)
        manager.processDeadlines()
        XCTAssertEqual(manager.current?.id, "second")
    }

    func testMultipleAutomaticToolsUseCurrentPeerThenAgeAndIDOrdering() throws {
        let clock = TestActivityClock(start)
        let manager = ActivityManager(clock: clock, configuration: .immediate)
        try manager.publish(tool("z-first"))
        try manager.publish(tool("a-first"))
        manager.setPresentationContext(.compact)
        XCTAssertEqual(manager.current?.id, "a-first", "Equal-age peers use stable IDs, not dictionary order.")
        let current = try XCTUnwrap(manager.currentSnapshot)
        clock.advance(by: 1)
        try manager.publish(tool("0-newer"))
        XCTAssertEqual(manager.currentSnapshot, current, "A current peer keeps its place.")
        try manager.end(id: "a-first", source: toolSource)
        XCTAssertEqual(manager.current?.id, "z-first", "Older admitted work precedes a lexically earlier new ID.")
        manager.setPresentationContext(.expanded)
        XCTAssertNil(manager.current)
        manager.setPresentationContext(.compact)
        XCTAssertEqual(manager.current?.id, "z-first")
        manager.endAll(source: toolSource)
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
    }

    private func snapshot(_ id: String, in manager: ActivityManager) throws -> ActivitySnapshot {
        try XCTUnwrap(manager.toolSnapshots.first { $0.activity.id == id })
    }

    private func tool(
        _ id: String, compactPolicy: ActivityPresentation.CompactPolicy? = .automatic,
        showsCompact: Bool = true, policy: ActivityLifecycle.Policy = .persistent
    ) -> IslandActivity {
        var presentation = ActivityPresentation(title: id, showsCompact: showsCompact, role: .tool)
        presentation.compactPolicy = compactPolicy
        return .init(id: id, source: toolSource, priority: .background, lifecycle: .init(policy: policy),
                     presentation: presentation, createdAt: start, actions: [.init(id: "run", title: "Run")])
    }

    private func status(
        _ id: String, priority: ActivityPriority, policy: ActivityLifecycle.Policy = .persistent
    ) -> IslandActivity {
        .init(id: id, source: statusSource, priority: priority, lifecycle: .init(policy: policy),
              presentation: .init(title: id), createdAt: start)
    }

    private func dispatch(_ router: ActionRouter, _ snapshot: ActivitySnapshot) -> ActionDispatchResult {
        router.dispatch(id: snapshot.activity.id, source: snapshot.activity.source,
                        instanceToken: snapshot.instanceToken, action: .init(actionID: "run", value: .none))
    }
}
