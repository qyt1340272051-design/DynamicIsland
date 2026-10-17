import Combine
import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class ActivityPresentationRequestTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 163_000)
    private let source = ActivitySource(kind: .plugin, identifier: "compatible.module")
    private let otherSource = ActivitySource(kind: .plugin, identifier: "other.module")
    private let musicSource = ActivitySource(kind: .builtIn, identifier: "music")

    func testHostMustExplicitlyAllowRequestsInAnExpandedContext() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let snapshot = try publishTool("module", manager: manager)
        XCTAssertEqual(manager.requestPresentation(snapshot), .init(status: .rejected, reason: .hostUnavailable))
        XCTAssertNil(manager.currentSnapshot)

        manager.setPresentationContext(.compact)
        manager.setPresentationRequestsAllowed(true)
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .hostUnavailable)
        manager.setPresentationRequestsAllowed(false)
        manager.setPresentationContext(.expanded)
        manager.setPresentationRequestsAllowed(true)
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .granted)
        XCTAssertEqual(manager.currentSnapshot?.instanceToken, snapshot.instanceToken)
        XCTAssertNil(manager.selectedToolSnapshot)
    }

    func testLeaseExpiryRestoresStatusWithoutEndingTheModuleOrSelectingItForUser() throws {
        let clock = TestActivityClock(start)
        let manager = ActivityManager(clock: clock, configuration: .immediate)
        try manager.publish(status("music", source: musicSource))
        let snapshot = try publishTool("module", manager: manager)
        manager.setPresentationRequestsAllowed(true)
        let decision = manager.requestPresentation(PresentationRequest(snapshot: snapshot))
        XCTAssertEqual(decision, .init(status: .accepted, reason: .granted, expiresAt: start.addingTimeInterval(3)))
        XCTAssertEqual(manager.current?.id, "module")
        XCTAssertNil(manager.selectedToolSnapshot)
        XCTAssertEqual(manager.diagnostics.scheduledWakeDeadline, decision.expiresAt)

        clock.advance(by: 3)
        manager.processDeadlines()
        XCTAssertEqual(manager.current?.id, "music")
        XCTAssertEqual(manager.activity(id: "module")?.lifecycle.state, .background)
        XCTAssertEqual(manager.toolSnapshots.first?.instanceToken, snapshot.instanceToken)
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .contextBudgetUsed)
    }

    func testManualDismissIsBoundedAndRepeatsNeverExtendTheDeadline() throws {
        let clock = TestActivityClock(start)
        let configuration = ActivityScheduler.Configuration(
            transientDuration: 2, maximumTransientContinuousDuration: 7,
            ordinaryDebounce: 0, minimumDwell: 0
        )
        let manager = ActivityManager(clock: clock, configuration: configuration)
        let snapshot = try publishTool("module", manager: manager)
        manager.setPresentationRequestsAllowed(true)
        let initial = manager.requestPresentation(snapshot, autoDismiss: false)
        XCTAssertEqual(initial, .init(status: .degraded, reason: .boundedDuration, expiresAt: start.addingTimeInterval(7)))
        clock.advance(by: 1)
        XCTAssertEqual(manager.requestPresentation(snapshot), .init(status: .accepted, reason: .alreadyGranted, expiresAt: initial.expiresAt))
        manager.setPresentationRequestsAllowed(true)
        clock.advance(by: 6)
        manager.processDeadlines()
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertNotNil(manager.activity(id: snapshot.activity.id))
        XCTAssertEqual(manager.requestPresentation(snapshot, autoDismiss: false).reason, .contextBudgetUsed)
    }

    func testWithdrawalOnlyRevokesItsOwnLeaseAndIsIdempotent() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let first = try publishTool("first", manager: manager)
        let other = try publishTool("other", source: otherSource, manager: manager)
        manager.setPresentationRequestsAllowed(true)
        XCTAssertEqual(manager.requestPresentation(first).reason, .granted)
        XCTAssertEqual(manager.requestPresentation(other).reason, .busy)
        XCTAssertEqual(manager.withdrawPresentation(other), .init(status: .accepted, reason: .noRequest))
        XCTAssertEqual(manager.current?.id, "first")
        XCTAssertEqual(manager.withdrawPresentation(first), .init(status: .accepted, reason: .withdrawn))
        XCTAssertEqual(manager.withdrawPresentation(first).reason, .noRequest)
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertEqual(manager.toolSnapshots.count, 2)
        XCTAssertEqual(manager.activity(id: "first")?.lifecycle.state, .background)
        XCTAssertEqual(manager.requestPresentation(other).reason, .contextBudgetUsed)
    }

    func testSuccessfulUserSelectionRevokesLeaseAndCannotBeDismissedByRequest() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let requested = try publishTool("requested", manager: manager)
        let chosen = try publishTool("chosen", source: otherSource, manager: manager)
        manager.setPresentationRequestsAllowed(true)
        XCTAssertEqual(manager.requestPresentation(requested).reason, .granted)
        XCTAssertTrue(manager.selectTool(chosen))
        XCTAssertEqual(manager.current?.id, "chosen")
        XCTAssertEqual(manager.withdrawPresentation(requested).reason, .noRequest)
        XCTAssertEqual(manager.withdrawPresentation(chosen).reason, .noRequest)
        XCTAssertEqual(manager.selectedToolSnapshot?.instanceToken, chosen.instanceToken)
        XCTAssertEqual(manager.requestPresentation(chosen).reason, .userSelection)
        manager.clearToolSelection()
        XCTAssertEqual(manager.requestPresentation(requested).reason, .contextBudgetUsed)
        XCTAssertNotNil(manager.activity(id: "requested"))
    }

    func testUserSelectionBeforeAnyGrantConsumesTheHostContextBudget() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let snapshot = try publishTool("module", manager: manager)
        manager.setPresentationRequestsAllowed(true)
        XCTAssertTrue(manager.selectTool(snapshot))
        manager.clearToolSelection()
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .contextBudgetUsed)
    }

    func testHostRevocationAndFoldRemoveLeaseAndOnlyANewContextResetsBudget() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let snapshot = try publishTool("module", manager: manager)
        manager.setPresentationRequestsAllowed(true)
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .granted)
        manager.setPresentationRequestsAllowed(false)
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .hostUnavailable)
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
        manager.setPresentationRequestsAllowed(true)
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .granted)
        manager.setPresentationContext(.compact)
        XCTAssertNil(manager.currentSnapshot)
        manager.setPresentationContext(.expanded)
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .hostUnavailable)
        manager.setPresentationRequestsAllowed(true)
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .granted)
    }

    func testRejectedRequestNeverQueuesASelectionForLaterExpansion() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let snapshot = try publishTool("module", manager: manager)
        manager.setPresentationContext(.compact)
        XCTAssertEqual(manager.requestPresentation(snapshot).status, .rejected)
        manager.setPresentationContext(.expanded)
        manager.setPresentationRequestsAllowed(true)
        manager.processDeadlines()
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .granted)
    }

    func testStatusesRevokeLeaseWithoutResumingItAfterTheyEnd() throws {
        for (priority, policy) in [
            (ActivityPriority.important, ActivityLifecycle.Policy.persistent),
            (.critical, .critical), (.normal, .transient)
        ] {
            let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
            let snapshot = try publishTool("module", manager: manager)
            manager.setPresentationRequestsAllowed(true)
            XCTAssertEqual(manager.requestPresentation(snapshot).reason, .granted)
            let event = status("event", source: musicSource, priority: priority, policy: policy)
            try manager.publish(event)
            XCTAssertEqual(manager.current?.id, event.id)
            XCTAssertEqual(manager.withdrawPresentation(snapshot).reason, .noRequest)
            XCTAssertEqual(manager.requestPresentation(snapshot).reason, .statusPriority)
            try manager.end(id: event.id, source: event.source)
            XCTAssertNil(manager.currentSnapshot)
            XCTAssertEqual(manager.requestPresentation(snapshot).reason, .contextBudgetUsed)
            XCTAssertNotNil(manager.activity(id: snapshot.activity.id))
        }
    }

    func testBlockingStatusRejectsBeforeAnyGrantWithoutUsingTheBudget() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let snapshot = try publishTool("module", manager: manager)
        let event = status("event", source: musicSource, priority: .important)
        try manager.publish(event)
        manager.setPresentationRequestsAllowed(true)
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .statusPriority)
        try manager.end(id: event.id, source: event.source)
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .granted)
    }

    func testOldInstanceCannotRequestOrWithdrawReplacementLease() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let original = try publishTool("module", manager: manager)
        manager.setPresentationRequestsAllowed(true)
        XCTAssertEqual(manager.requestPresentation(original).reason, .granted)
        try manager.end(id: original.activity.id, source: source)
        let replacement = try publishTool("module", manager: manager)
        XCTAssertNotEqual(original.instanceToken, replacement.instanceToken)
        XCTAssertEqual(manager.requestPresentation(original).reason, .staleInstance)
        manager.setPresentationRequestsAllowed(false)
        manager.setPresentationRequestsAllowed(true)
        XCTAssertEqual(manager.requestPresentation(replacement).reason, .granted)
        XCTAssertEqual(manager.withdrawPresentation(original).reason, .noRequest)
        XCTAssertEqual(manager.currentSnapshot?.instanceToken, replacement.instanceToken)
    }

    func testNonToolAndChangedRoleDoNotRetainRequestEligibility() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let snapshot = try publishTool("module", manager: manager)
        manager.setPresentationRequestsAllowed(true)
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .granted)
        var changed = snapshot.activity
        changed.presentation = .init(title: "Now a status")
        try manager.update(changed)
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .invalidActivity)
        XCTAssertEqual(manager.withdrawPresentation(snapshot).reason, .noRequest)
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
    }

    func testDisabledSourceRevokesLeaseAndDoesNotRegainItOnEnablement() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        manager.requirePluginActivation()
        manager.setPluginSourceEnabled(true, for: source)
        let snapshot = try publishTool("module", manager: manager)
        manager.setPresentationRequestsAllowed(true)
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .granted)
        manager.setPluginSourceEnabled(false, for: source)
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertEqual(manager.withdrawPresentation(snapshot).reason, .noRequest)
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .invalidActivity)
        manager.setPluginSourceEnabled(true, for: source)
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .contextBudgetUsed)
    }

    func testRenderUpdateRetainsInstanceAndNeverRenewsLease() throws {
        let clock = TestActivityClock(start)
        let manager = ActivityManager(clock: clock, configuration: .immediate)
        let snapshot = try publishTool("module", manager: manager)
        manager.setPresentationRequestsAllowed(true)
        let decision = manager.requestPresentation(snapshot)
        clock.advance(by: 2)
        var updated = snapshot.activity
        updated.presentation.title = "New module render"
        try manager.update(updated)
        XCTAssertEqual(manager.current?.presentation.title, "New module render")
        XCTAssertEqual(manager.currentSnapshot?.instanceToken, snapshot.instanceToken)
        XCTAssertEqual(manager.requestPresentation(snapshot).expiresAt, decision.expiresAt)
        clock.advance(by: 1)
        manager.processDeadlines()
        XCTAssertNil(manager.currentSnapshot)
    }

    func testRequestsRetainOrdinaryDebounceAndDwell() throws {
        let clock = TestActivityClock(start)
        let manager = ActivityManager(clock: clock)
        try manager.publish(status("music", source: musicSource))
        let snapshot = try publishTool("module", manager: manager)
        manager.setPresentationRequestsAllowed(true)
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .granted)
        XCTAssertEqual(manager.current?.id, "music")
        clock.advance(by: 0.49)
        manager.processDeadlines()
        XCTAssertEqual(manager.current?.id, "music")
        clock.advance(by: 0.01)
        manager.processDeadlines()
        XCTAssertEqual(manager.current?.id, "module")
        XCTAssertNil(manager.selectedToolSnapshot)
    }

    func testSourceRateLimitMayOutlastTheLeaseWithoutLaterResurrectingIt() throws {
        let clock = TestActivityClock(start)
        let configuration = ActivityScheduler.Configuration(
            ordinaryDebounce: 0, minimumDwell: 0, minimumIntervalBySource: [source: 10]
        )
        let manager = ActivityManager(clock: clock, configuration: configuration)
        try manager.publish(status("previous", source: source))
        try manager.end(id: "previous", source: source)
        let snapshot = try publishTool("module", manager: manager)
        manager.setPresentationRequestsAllowed(true)
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .granted)
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertEqual(manager.diagnostics.scheduledWakeDeadline, start.addingTimeInterval(3))
        clock.advance(by: 10)
        manager.processDeadlines()
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertEqual(manager.activity(id: "module")?.lifecycle.state, .queued)
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .contextBudgetUsed)
    }

    func testSharedSchedulerExpiresLeaseWithoutAnExplicitDeadlineCall() async throws {
        let clock = TestActivityClock(start)
        let manager = ActivityManager(clock: clock, configuration: .immediate)
        let snapshot = try publishTool("module", manager: manager)
        manager.setPresentationRequestsAllowed(true)
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .granted)
        clock.advance(by: 3)
        let timeout = ContinuousClock.now.advanced(by: .seconds(2))
        while manager.currentSnapshot != nil, ContinuousClock.now < timeout {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertNotNil(manager.activity(id: "module"))
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
    }

    func testSynchronousHostRevocationDuringPublicationCannotLeaveGhostPresentation() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let snapshot = try publishTool("module", manager: manager)
        manager.setPresentationRequestsAllowed(true)
        var revoked = false
        let observation = manager.$currentSnapshot.dropFirst().sink { next in
            guard next?.activity.id == "module", !revoked else { return }
            revoked = true
            manager.setPresentationRequestsAllowed(false)
        }
        let decision = manager.requestPresentation(snapshot)
        XCTAssertTrue(revoked)
        XCTAssertEqual(decision.status, .rejected)
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertNil(manager.current)
        XCTAssertEqual(manager.activity(id: "module")?.lifecycle.state, .background)
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
        withExtendedLifetime(observation) {}
    }

    func testSynchronousSourceRemovalDuringPublicationCannotRestoreOrRetainItsState() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let snapshot = try publishTool("module", manager: manager)
        manager.setPresentationRequestsAllowed(true)
        var removed = false
        let observation = manager.$currentSnapshot.dropFirst().sink { next in
            guard next?.activity.id == "module", !removed else { return }
            removed = true
            manager.endAll(source: self.source)
        }
        let decision = manager.requestPresentation(snapshot)
        XCTAssertTrue(removed)
        XCTAssertEqual(decision.status, .rejected)
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertNil(manager.current)
        XCTAssertNil(manager.activity(id: "module"))
        XCTAssertEqual(manager.diagnostics.activityCount, 0)
        XCTAssertEqual(manager.diagnostics.firstPresentedCount, 0)
        XCTAssertEqual(manager.diagnostics.displayDeadlineCount, 0)
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
        withExtendedLifetime(observation) {}
    }

    func testSynchronousToolInventoryRemovalIsReconciledAfterTheSetterFinishes() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        var removed = false
        let observation = manager.$toolSnapshots.dropFirst().sink { snapshots in
            guard snapshots.contains(where: { $0.activity.id == "module" }), !removed else { return }
            removed = true
            manager.endAll(source: self.source)
        }
        let tool = IslandActivity(id: "module", source: source, priority: .background,
            lifecycle: .init(policy: .persistent),
            presentation: .init(title: "Module", role: .tool), createdAt: start)
        try manager.publish(tool)
        XCTAssertTrue(removed)
        XCTAssertTrue(manager.toolSnapshots.isEmpty)
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertNil(manager.current)
        XCTAssertEqual(manager.diagnostics.activityCount, 0)
        XCTAssertEqual(manager.diagnostics.instanceTokenCount, 0)
        XCTAssertEqual(manager.diagnostics.firstPresentedCount, 0)
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
        withExtendedLifetime(observation) {}
    }

    func testSynchronousDeadlineObserverDoesNotRecursivelyPublishOrLoseLeaseMetadata() throws {
        let clock = TestActivityClock(start)
        let manager = ActivityManager(clock: clock, configuration: .immediate)
        let snapshot = try publishTool("module", manager: manager)
        manager.setPresentationRequestsAllowed(true)
        var modulePublications = 0
        let observation = manager.$currentSnapshot.dropFirst().sink { next in
            if next?.activity.id == "module" { modulePublications += 1 }
            manager.processDeadlines()
        }
        XCTAssertEqual(manager.requestPresentation(snapshot).reason, .granted)
        XCTAssertEqual(modulePublications, 1)
        XCTAssertEqual(manager.current?.id, "module")
        XCTAssertEqual(manager.currentSnapshot?.activity.id, "module")
        XCTAssertEqual(manager.diagnostics.firstPresentedCount, 1)
        XCTAssertEqual(manager.diagnostics.scheduledWakeDeadline, start.addingTimeInterval(3))
        clock.advance(by: 3)
        manager.processDeadlines()
        XCTAssertNil(manager.current)
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
        withExtendedLifetime(observation) {}
    }

    func testSynchronousDeadlineObserverDoesNotLeaveTransientWithoutItsDeadline() throws {
        let clock = TestActivityClock(start)
        let manager = ActivityManager(clock: clock, configuration: .immediate)
        let observation = manager.$currentSnapshot.dropFirst().sink { _ in manager.processDeadlines() }
        try manager.publish(status("event", source: musicSource, priority: .normal, policy: .transient))
        XCTAssertEqual(manager.current?.id, "event")
        XCTAssertEqual(manager.diagnostics.firstPresentedCount, 1)
        XCTAssertEqual(manager.diagnostics.displayDeadlineCount, 1)
        clock.advance(by: 3)
        manager.processDeadlines()
        XCTAssertNil(manager.current)
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertNil(manager.activity(id: "event"))
        XCTAssertEqual(manager.diagnostics.firstPresentedCount, 0)
        XCTAssertEqual(manager.diagnostics.displayDeadlineCount, 0)
        XCTAssertNil(manager.diagnostics.scheduledWakeDeadline)
        withExtendedLifetime(observation) {}
    }

    func testActionLookupInsidePendingRevocationCannotUseThePreviousPresentation() throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let snapshot = try publishTool("module", manager: manager)
        manager.setPresentationRequestsAllowed(true)
        var attempted = false
        var admittedAction: IslandActivity?
        let observation = manager.$current.dropFirst().sink { next in
            guard next?.id == "module", !attempted else { return }
            attempted = true
            manager.setPresentationRequestsAllowed(false)
            admittedAction = manager.activeActionActivity(id: snapshot.activity.id,
                source: snapshot.activity.source, instanceToken: snapshot.instanceToken)
        }
        XCTAssertEqual(manager.requestPresentation(snapshot).status, .rejected)
        XCTAssertTrue(attempted)
        XCTAssertNil(admittedAction)
        XCTAssertNil(manager.currentSnapshot)
        XCTAssertNil(manager.current)
        withExtendedLifetime(observation) {}
    }

    private func publishTool(_ id: String, source requestedSource: ActivitySource? = nil,
                             manager: ActivityManager) throws -> ActivitySnapshot {
        let tool = IslandActivity(id: id, source: requestedSource ?? source, priority: .background,
            lifecycle: .init(policy: .persistent),
            presentation: .init(title: id, compact: .text(.init(id)), expanded: .text(.init(id)),
                                showsCompact: true, role: .tool, compactPolicy: .selectedOnly),
            createdAt: start)
        try manager.publish(tool)
        return try XCTUnwrap(manager.toolSnapshots.first { $0.activity.id == id })
    }

    private func status(_ id: String, source: ActivitySource, priority: ActivityPriority = .background,
                        policy: ActivityLifecycle.Policy = .persistent) -> IslandActivity {
        .init(id: id, source: source, priority: priority, lifecycle: .init(policy: policy),
              presentation: .init(title: id), createdAt: start)
    }
}
