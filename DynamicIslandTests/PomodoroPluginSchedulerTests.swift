import Combine
import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PomodoroPluginSchedulerTests: XCTestCase {
    func testOfficialRefreshHonorsBackgroundAndLowPowerFloorsAndReconcilesOnlyOnce() async throws {
        for (policy, deadline) in [(PluginSchedulerPolicy.background, 30.0), (.lowPower, 60.0)] {
            let f = try PomodoroPluginFixture()
            defer { f.shutdown() }
            f.scheduler.setPolicy(policy)
            try f.grantStorage()
            try await f.load()
            try await waitForPendingRefresh(f)
            XCTAssertEqual(f.scheduler.snapshot.nextDeadline, deadline)
            XCTAssertEqual(f.scheduler.snapshot.timerCount, 0, "The fixture uses a manual Host clock.")
            try f.act("start")
            try await f.waitForState("专注中")
            try await f.flushWorker()
            let running = try XCTUnwrap(try f.record())

            // Change authoritative Host state while the VM still shows running.
            // The refresh must actually read it, without starting a new record.
            f.clock.now = .seconds(1)
            let paused = try f.broker.pause(owner: f.owner(), id: running.id, generation: running.generation)
            let publications = f.clock.publicationCount
            f.clock.schedulerNow = deadline - 0.001
            f.scheduler.processDue()
            try await f.flushWorker()
            XCTAssertEqual(f.tool?.presentation.subtitle, "25 分钟 · 专注中")
            XCTAssertTrue(f.references.allSatisfy { $0.generation == running.generation.rawValue })
            XCTAssertEqual(f.scheduler.snapshot.pendingCount, 1)
            XCTAssertEqual(f.scheduler.snapshot.wakeCount, 0)

            f.clock.schedulerNow = deadline
            f.scheduler.processDue()
            try await f.waitForState("已暂停")
            try await f.flushWorker()
            XCTAssertGreaterThan(f.clock.publicationCount, publications)
            XCTAssertEqual(f.scheduler.snapshot.pendingCount, 0)
            XCTAssertEqual(f.scheduler.snapshot.wakeCount, 1)
            XCTAssertNil(f.scheduler.snapshot.nextDeadline)
            XCTAssertEqual(try f.record(), paused)
            XCTAssertTrue(f.references.allSatisfy { $0.generation == paused.generation.rawValue })
            let reconciledPublications = f.clock.publicationCount

            f.clock.schedulerNow = deadline + 3_600
            f.scheduler.processDue()
            try await f.flushWorker()
            XCTAssertEqual(f.clock.publicationCount, reconciledPublications)
            XCTAssertEqual(f.scheduler.snapshot.wakeCount, 1)
            XCTAssertEqual(f.scheduler.snapshot.pendingCount, 0)
            XCTAssertEqual(try f.record(), paused)
            f.assertNoFailures()
        }
    }

    func testStricterPolicyPostponesTheRealVMRequestAndRelaxingDoesNotCatchUp() async throws {
        let f = try PomodoroPluginFixture()
        defer { f.shutdown() }
        try f.grantStorage()
        try await f.load()
        try await waitForPendingRefresh(f)
        XCTAssertEqual(f.scheduler.snapshot.nextDeadline, 30)
        let publications = f.clock.publicationCount

        f.clock.schedulerNow = 10
        f.scheduler.setPolicy(.lowPower)
        XCTAssertEqual(f.scheduler.snapshot.nextDeadline, 75, "The 60s floor rounds up to a 15s bucket.")
        f.clock.schedulerNow = 20
        f.scheduler.setPolicy(.active)
        XCTAssertEqual(f.scheduler.snapshot.nextDeadline, 75)
        for instant in [30.0, 60.0, 74.999] {
            f.clock.schedulerNow = instant
            f.scheduler.processDue()
            try await f.flushWorker()
            XCTAssertEqual(f.scheduler.snapshot.pendingCount, 1)
        }
        f.clock.schedulerNow = 75
        f.scheduler.processDue()
        try await f.waitUntil { f.clock.publicationCount > publications }
        try await f.flushWorker()
        XCTAssertGreaterThan(f.clock.publicationCount, publications)
        XCTAssertEqual(f.scheduler.snapshot.pendingCount, 0)
        XCTAssertEqual(f.scheduler.snapshot.wakeCount, 1)
        XCTAssertNil(try f.record(), "A reconciliation never starts an idle timer.")
        let reconciledPublications = f.clock.publicationCount
        f.clock.schedulerNow = 3_600
        f.scheduler.processDue()
        try await f.flushWorker()
        XCTAssertEqual(f.clock.publicationCount, reconciledPublications)
        XCTAssertEqual(f.scheduler.snapshot.pendingCount, 0)
        f.assertNoFailures()
    }

    func testDisableRevokesOldRefreshAndNewExecutionGetsItsOwnSingleRequest() async throws {
        let f = try PomodoroPluginFixture()
        defer { f.shutdown() }
        try f.grantStorage()
        try await f.load()
        try await waitForPendingRefresh(f)
        let oldContext = try f.context()
        let publications = f.clock.publicationCount
        f.clock.schedulerNow = 10
        f.lifecycle.pluginDidChangeEnablement(id: f.id, isEnabled: false)
        try await f.waitUntil { f.scheduler.snapshot.pendingCount == 0 }
        XCTAssertThrowsError(try oldContext.perform {})
        XCTAssertTrue(f.manager.toolSnapshots.isEmpty)
        f.clock.schedulerNow = 30
        f.scheduler.processDue()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(f.clock.publicationCount, publications)
        XCTAssertEqual(f.scheduler.snapshot.wakeCount, 0)
        XCTAssertEqual(f.broker.diagnostics.recordCount, 0)

        f.clock.schedulerNow = 35
        f.lifecycle.pluginDidChangeEnablement(id: f.id, isEnabled: true)
        try await f.waitForState("准备专注")
        try await waitForPendingRefresh(f)
        XCTAssertEqual(f.runtimes.count, 2)
        XCTAssertEqual(f.scheduler.snapshot.nextDeadline, 65)
        let replacementPublications = f.clock.publicationCount
        f.clock.schedulerNow = 64.999
        f.scheduler.processDue()
        try await f.flushWorker()
        XCTAssertEqual(f.clock.publicationCount, replacementPublications)
        f.clock.schedulerNow = 65
        f.scheduler.processDue()
        try await f.waitUntil { f.clock.publicationCount > replacementPublications }
        try await f.flushWorker()
        XCTAssertGreaterThan(f.clock.publicationCount, replacementPublications)
        XCTAssertEqual(f.scheduler.snapshot.pendingCount, 0)
        XCTAssertEqual(f.scheduler.snapshot.wakeCount, 1)
        XCTAssertNil(try f.record())
        f.assertNoFailures()
    }

    func testSuspensionRevokesOldRefreshAndResumePreservesRecordWithFreshRequest() async throws {
        let f = try PomodoroPluginFixture()
        defer { f.shutdown() }
        try f.grantStorage()
        try await f.load()
        try await waitForPendingRefresh(f)
        try f.act("start")
        try await f.waitForState("专注中")
        let running = try XCTUnwrap(try f.record())
        let owner = try f.owner()
        let oldContext = try f.context()
        f.clock.schedulerNow = 10
        f.clock.now = .seconds(10)
        f.lifecycle.setEnvironment(isSleeping: true, isLowBattery: false)
        try await f.waitUntil { f.scheduler.snapshot.pendingCount == 0 }
        XCTAssertThrowsError(try oldContext.perform {})
        XCTAssertEqual(f.broker.diagnostics.recordCount, 1)

        f.clock.schedulerNow = 20
        f.clock.now = .seconds(20)
        f.lifecycle.setEnvironment(isSleeping: false, isLowBattery: false)
        try await f.waitForState("专注中")
        try await waitForPendingRefresh(f)
        XCTAssertEqual(f.runtimes.count, 2)
        XCTAssertEqual(try f.owner(), owner)
        XCTAssertEqual(try f.record()?.generation, running.generation)
        XCTAssertEqual(f.scheduler.snapshot.nextDeadline, 50)
        let publications = f.clock.publicationCount
        f.clock.schedulerNow = 30
        f.scheduler.processDue()
        try await f.flushWorker()
        XCTAssertEqual(f.clock.publicationCount, publications, "The old execution's deadline must remain revoked.")
        XCTAssertEqual(f.scheduler.snapshot.pendingCount, 1)

        f.clock.schedulerNow = 50
        f.clock.now = .seconds(50)
        f.scheduler.processDue()
        try await f.waitUntil { f.clock.publicationCount > publications }
        try await f.flushWorker()
        XCTAssertGreaterThan(f.clock.publicationCount, publications)
        XCTAssertEqual(f.scheduler.snapshot.pendingCount, 0)
        XCTAssertEqual(f.scheduler.snapshot.wakeCount, 1)
        let restored = try XCTUnwrap(try f.record())
        XCTAssertEqual(restored.generation, running.generation)
        XCTAssertEqual(restored.remaining, running.remaining - .seconds(50))
        XCTAssertEqual(restored.state, .running)
        f.assertNoFailures()
    }

    func testRefreshAndCompletionObserverProduceOneCompletionAndNeverAutoStart() async throws {
        let f = try PomodoroPluginFixture()
        defer { f.shutdown() }
        try f.grantStorage()
        try await f.load()
        try await waitForPendingRefresh(f)
        let capture = PomodoroSchedulerCompletionCapture()
        let observation = f.manager.$currentSnapshot.sink { snapshot in
            guard let snapshot, snapshot.activity.id == f.completionID else { return }
            capture.tokens.append(snapshot.instanceToken)
        }
        try f.act("preset.15")
        try await f.waitForState("准备专注", minutes: 15)
        try f.act("start")
        try await f.waitForState("专注中", minutes: 15)
        let running = try XCTUnwrap(try f.record())
        f.clock.now += running.remaining
        f.clock.schedulerNow = 30
        f.scheduler.processDue()
        try await f.waitForState("本轮已完成", minutes: 15)
        try await f.waitUntil { f.manager.activity(id: f.completionID) != nil }
        try await f.flushWorker()
        XCTAssertEqual(capture.tokens.count, 1)
        XCTAssertEqual(f.scheduler.snapshot.pendingCount, 0)
        let publications = f.clock.publicationCount
        f.activityClock.advance(by: 3)
        f.manager.processDeadlines()
        XCTAssertNil(f.manager.activity(id: f.completionID))
        for _ in 0..<3 { f.broker.processDue(); await Task.yield() }
        f.clock.schedulerNow = 3_600
        f.scheduler.processDue()
        try await f.flushWorker()
        XCTAssertEqual(capture.tokens.count, 1)
        XCTAssertEqual(f.clock.publicationCount, publications)
        XCTAssertEqual(try f.record()?.generation, running.generation)
        XCTAssertEqual(try f.record()?.state, .completed)
        XCTAssertEqual(f.broker.diagnostics.runningCount, 0)
        XCTAssertEqual(f.broker.diagnostics.completedCount, 1)
        XCTAssertEqual(f.scheduler.snapshot.pendingCount, 0)
        f.assertNoFailures()
        withExtendedLifetime(observation) {}
    }

    func testSingleRefreshRestoresNewlyAuthorizedSettingsWhenUserHasNotChangedThem() async throws {
        let f = try PomodoroPluginFixture()
        defer { f.shutdown() }
        try await seedSettings(f, minutes: 45)
        try await f.load()
        try await waitForPendingRefresh(f)
        XCTAssertEqual(f.tool?.presentation.subtitle, "25 分钟 · 准备专注")
        XCTAssertNil(try f.record())
        try f.grantStorage()
        let publications = f.clock.publicationCount
        f.clock.schedulerNow = 30
        f.scheduler.processDue()
        try await f.waitForState("准备专注", minutes: 45)
        try await f.flushWorker()
        XCTAssertGreaterThan(f.clock.publicationCount, publications)
        XCTAssertEqual(f.scheduler.snapshot.pendingCount, 0)
        XCTAssertNil(try f.record())
        XCTAssertFalse(try XCTUnwrap(f.tool).presentation.isCompactVisible)
        XCTAssertNil(f.lifecycle.snapshot(id: f.id)?.lastFailure)
    }

    func testNewAuthorizationCannotOverwriteUserChangesEvenAfterReturningToDefault() async throws {
        let f = try PomodoroPluginFixture()
        defer { f.shutdown() }
        try await seedSettings(f, minutes: 45)
        try await f.load()
        try await waitForPendingRefresh(f)
        try f.act("preset.60")
        try await f.waitForState("准备专注", minutes: 60)
        try f.act("preset.25")
        try await f.waitForState("准备专注", minutes: 25)
        try f.grantStorage()
        let publications = f.clock.publicationCount
        f.clock.schedulerNow = 30
        f.scheduler.processDue()
        try await f.waitUntil { f.clock.publicationCount > publications }
        try await f.flushWorker()
        XCTAssertEqual(f.tool?.presentation.subtitle, "25 分钟 · 准备专注")
        XCTAssertGreaterThan(f.clock.publicationCount, publications)
        XCTAssertEqual(f.scheduler.snapshot.pendingCount, 0)
        XCTAssertNil(try f.record())
        XCTAssertNil(f.lifecycle.snapshot(id: f.id)?.lastFailure)
    }

    private func waitForPendingRefresh(_ f: PomodoroPluginFixture) async throws {
        try await f.waitUntil { f.scheduler.snapshot.pendingCount == 1 }
        try await f.flushWorker()
    }

    private func seedSettings(_ f: PomodoroPluginFixture, minutes: Int) async throws {
        try await f.storage.set(pluginID: f.id, key: "settings", value: .object([
            "schemaVersion": .number(1), "selectedMinutes": .number(Double(minutes)), "lastSession": .string("idle")
        ]))
    }
}

@MainActor
private final class PomodoroSchedulerCompletionCapture { var tokens: [ActivityInstanceToken] = [] }
