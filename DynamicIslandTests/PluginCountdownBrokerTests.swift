import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginCountdownBrokerTests: XCTestCase {
    func testDurationAndLocalIDBoundsRejectWithoutChangingExistingGeneration() throws {
        let clock = CountdownBrokerClock()
        let broker = makeBroker(clock)
        defer { broker.shutdown() }
        let owner = try broker.registerOwner(pluginID: "com.example.clock")
        let original = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        for duration in [Int.min, -1, 0, 999, 86_400_001, Int.max] {
            assertError(.invalidArguments) {
                try broker.start(owner: owner, id: "focus", durationMilliseconds: duration)
            }
            XCTAssertEqual(try broker.get(owner: owner, id: "focus"), original)
        }
        for id in ["", "with/path", "with:colon", "with space", String(repeating: "a", count: 81)] {
            assertError(.invalidArguments) { try broker.start(owner: owner, id: id, durationMilliseconds: 1_000) }
        }
        let maximum = try broker.start(owner: owner, id: "focus", durationMilliseconds: 86_400_000)
        XCTAssertEqual(maximum.remaining, .seconds(86_400))
        XCTAssertNotEqual(maximum.generation, original.generation)
        try broker.stop(owner: owner, id: "focus", generation: maximum.generation)
        let maximumID = String(repeating: "a", count: 80)
        XCTAssertEqual(try broker.start(owner: owner, id: maximumID, durationMilliseconds: 1_000).id, maximumID)
    }

    func testDurationClockControlsExactBoundaryAndSleepJumpCompletesOnlyOnce() throws {
        let clock = CountdownBrokerClock()
        let probe = CountdownBrokerCompletionProbe()
        let broker = makeBroker(clock)
        defer { broker.shutdown() }
        let owner = try broker.registerOwner(pluginID: "com.example.clock")
        try observe(broker, owner: owner, probe: probe)
        let started = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        clock.now = .seconds(1) - .nanoseconds(1)
        broker.processDue()
        XCTAssertTrue(probe.events.isEmpty)
        XCTAssertEqual(try broker.get(owner: owner, id: "focus")?.remaining, Duration.nanoseconds(1))
        clock.now = .seconds(1)
        broker.processDue()
        XCTAssertEqual(probe.events.map(\.owner), [owner])
        XCTAssertEqual(probe.events.map(\.generation), [started.generation])
        XCTAssertEqual(probe.events.first?.snapshot.state, .completed)
        XCTAssertEqual(probe.events.first?.snapshot.remaining, Duration.zero)
        XCTAssertEqual(try broker.get(owner: owner, id: "focus")?.state, .completed)
        XCTAssertEqual(try broker.get(owner: owner, id: "focus")?.remaining, Duration.zero)

        let next = try broker.start(owner: owner, id: "focus", durationMilliseconds: 60_000)
        // No Date or real elapsed wall time participates: this Duration jump
        // models the continuous clock advancing while the computer slept.
        clock.now = .seconds(86_400)
        broker.processDue()
        broker.processDue()
        XCTAssertEqual(probe.events.map(\.generation), [started.generation, next.generation])
        XCTAssertNil(broker.diagnostics.nextDeadline)
        XCTAssertEqual(broker.diagnostics.alarmCount, 0)
    }

    func testPausePreservesNanosecondRemainderAndResumeRotatesGeneration() throws {
        let clock = CountdownBrokerClock()
        let probe = CountdownBrokerCompletionProbe()
        let broker = makeBroker(clock)
        defer { broker.shutdown() }
        let owner = try broker.registerOwner(pluginID: "com.example.clock")
        try observe(broker, owner: owner, probe: probe)
        let started = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_001)
        clock.now = .nanoseconds(123_456_789)
        let paused = try broker.pause(owner: owner, id: "focus", generation: started.generation)
        let exactRemaining = Duration.milliseconds(1_001) - .nanoseconds(123_456_789)
        XCTAssertEqual(paused.remaining, exactRemaining)
        XCTAssertEqual(paused.state, .paused)
        XCTAssertNotEqual(paused.generation, started.generation)
        XCTAssertNil(broker.diagnostics.nextDeadline)
        clock.now = .seconds(21_600)
        broker.processDue()
        XCTAssertEqual(try broker.get(owner: owner, id: "focus")?.remaining, exactRemaining)
        XCTAssertTrue(probe.events.isEmpty)
        assertError(.staleGeneration) {
            try broker.resume(owner: owner, id: "focus", generation: started.generation)
        }
        let resumedAt = clock.now
        let resumed = try broker.resume(owner: owner, id: "focus", generation: paused.generation)
        XCTAssertNotEqual(resumed.generation, paused.generation)
        XCTAssertEqual(resumed.remaining, exactRemaining)
        clock.now = resumedAt + exactRemaining - .nanoseconds(1)
        broker.processDue()
        XCTAssertTrue(probe.events.isEmpty)
        clock.now += .nanoseconds(1)
        broker.processDue()
        XCTAssertEqual(probe.events.map(\.generation), [resumed.generation])
    }

    func testPauseAtDeadlineCompletesAndCannotResumeExpiredTime() throws {
        let clock = CountdownBrokerClock()
        let probe = CountdownBrokerCompletionProbe()
        let broker = makeBroker(clock)
        defer { broker.shutdown() }
        let owner = try broker.registerOwner(pluginID: "com.example.clock")
        try observe(broker, owner: owner, probe: probe)
        let started = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        assertError(.invalidState) { try broker.resume(owner: owner, id: "focus", generation: started.generation) }
        clock.now = .seconds(1)
        assertError(.invalidState) { try broker.pause(owner: owner, id: "focus", generation: started.generation) }
        XCTAssertEqual(probe.events.count, 1)
        assertError(.invalidState) { try broker.resume(owner: owner, id: "focus", generation: started.generation) }
        XCTAssertEqual(try broker.get(owner: owner, id: "focus")?.state, .completed)
        try broker.stop(owner: owner, id: "focus", generation: started.generation)
        XCTAssertNil(try broker.get(owner: owner, id: "focus"))
    }

    func testSameIDRestartIsAtomicAndOldCommandsOrDueWorkCannotAffectReplacement() throws {
        let clock = CountdownBrokerClock()
        let probe = CountdownBrokerCompletionProbe()
        let broker = makeBroker(clock)
        defer { broker.shutdown() }
        let owner = try broker.registerOwner(pluginID: "com.example.clock")
        try observe(broker, owner: owner, probe: probe)
        let old = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        clock.now = .seconds(1)
        let replacement = try broker.start(owner: owner, id: "focus", durationMilliseconds: 2_000)
        XCTAssertNotEqual(old.generation, replacement.generation)
        assertError(.staleGeneration) { try broker.stop(owner: owner, id: "focus", generation: old.generation) }
        assertError(.staleGeneration) { try broker.pause(owner: owner, id: "focus", generation: old.generation) }
        assertError(.staleGeneration) { try broker.resume(owner: owner, id: "focus", generation: old.generation) }
        assertError(.quotaExceeded) { try broker.start(owner: owner, id: "other", durationMilliseconds: 1_000) }
        broker.processDue()
        XCTAssertTrue(probe.events.isEmpty)
        XCTAssertEqual(try broker.get(owner: owner, id: "focus"), replacement)
        clock.now = .seconds(3)
        broker.processDue()
        XCTAssertEqual(probe.events.map(\.generation), [replacement.generation])
        XCTAssertEqual(broker.diagnostics.recordCount, 1)
    }

    func testOwnerReplacementRejectsAllStaleOwnerOperationsAndDuplicateRegistration() throws {
        let clock = CountdownBrokerClock()
        let broker = makeBroker(clock)
        defer { broker.shutdown() }
        let old = try broker.registerOwner(pluginID: "com.example.clock")
        let oldRecord = try broker.start(owner: old, id: "focus", durationMilliseconds: 1_000)
        let current = try broker.replaceOwner(old)
        XCTAssertNotEqual(current, old)
        let replacement = try broker.start(owner: current, id: "focus", durationMilliseconds: 2_000)
        assertError(.ownerAlreadyRegistered) { try broker.registerOwner(pluginID: old.pluginID) }
        assertError(.inactiveOwner) { try broker.replaceOwner(old) }
        assertError(.inactiveOwner) { try broker.removeOwner(old) }
        assertError(.inactiveOwner) { try broker.suspendOwner(old) }
        assertError(.inactiveOwner) { try broker.reactivateOwner(old) }
        assertError(.inactiveOwner) { try broker.start(owner: old, id: "focus", durationMilliseconds: 1_000) }
        assertError(.inactiveOwner) { try broker.get(owner: old, id: "focus") }
        assertError(.inactiveOwner) { try broker.pause(owner: old, id: "focus", generation: oldRecord.generation) }
        assertError(.inactiveOwner) { try broker.resume(owner: old, id: "focus", generation: oldRecord.generation) }
        assertError(.inactiveOwner) { try broker.stop(owner: old, id: "focus", generation: oldRecord.generation) }
        XCTAssertEqual(try broker.get(owner: current, id: "focus"), replacement)
        XCTAssertEqual(broker.diagnostics.ownerCount, 1)
        try broker.removeOwner(current)
        let fresh = try broker.registerOwner(pluginID: old.pluginID)
        XCTAssertNotEqual(fresh, old)
        XCTAssertNotEqual(fresh, current)
        XCTAssertNil(try broker.get(owner: fresh, id: "focus"))
    }

    func testSuspendedOwnerRetainsContinuousDeadlineAndPausedOwnerStaysFrozen() throws {
        let clock = CountdownBrokerClock()
        let probe = CountdownBrokerCompletionProbe()
        let broker = makeBroker(clock)
        defer { broker.shutdown() }
        let runningOwner = try broker.registerOwner(pluginID: "com.example.running")
        let pausedOwner = try broker.registerOwner(pluginID: "com.example.paused")
        try observe(broker, owner: runningOwner, probe: probe)
        try observe(broker, owner: pausedOwner, probe: probe)
        let running = try broker.start(owner: runningOwner, id: "focus", durationMilliseconds: 1_000)
        let other = try broker.start(owner: pausedOwner, id: "focus", durationMilliseconds: 2_000)
        clock.now = .milliseconds(250)
        let paused = try broker.pause(owner: pausedOwner, id: "focus", generation: other.generation)
        try broker.suspendOwner(runningOwner)
        try broker.suspendOwner(pausedOwner)
        XCTAssertNil(broker.diagnostics.nextDeadline)
        clock.now = .seconds(86_400)
        broker.processDue()
        XCTAssertTrue(probe.events.isEmpty)
        XCTAssertEqual(broker.diagnostics.runningCount, 1)
        assertError(.inactiveOwner) { try broker.get(owner: runningOwner, id: "focus") }
        try broker.reactivateOwner(runningOwner)
        try broker.reactivateOwner(runningOwner)
        XCTAssertEqual(probe.events.map(\.owner), [runningOwner])
        XCTAssertEqual(probe.events.map(\.generation), [running.generation])
        try broker.reactivateOwner(pausedOwner)
        XCTAssertEqual(try broker.get(owner: pausedOwner, id: "focus"), paused)
        XCTAssertNil(broker.diagnostics.nextDeadline)
    }

    func testOwnerAndRecordQuotasReleaseOnlyTheRemovedOwnerAndRemainBounded() throws {
        let clock = CountdownBrokerClock()
        let broker = makeBroker(clock)
        defer { broker.shutdown() }
        var owners: [PluginCountdownOwner] = []
        var snapshots: [PluginCountdownSnapshot] = []
        assertError(.invalidArguments) { try broker.registerOwner(pluginID: "not a plugin") }
        for index in 0..<128 {
            let owner = try broker.registerOwner(pluginID: "com.example.p\(index)")
            owners.append(owner)
            snapshots.append(try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000))
        }
        XCTAssertEqual(broker.diagnostics.ownerCount, 128)
        XCTAssertEqual(broker.diagnostics.recordCount, 128)
        assertError(.quotaExceeded) { try broker.registerOwner(pluginID: "com.example.overflow") }
        assertError(.quotaExceeded) { try broker.start(owner: owners[0], id: "other", durationMilliseconds: 1_000) }
        let restarted = try broker.start(owner: owners[0], id: "focus", durationMilliseconds: 2_000)
        XCTAssertNotEqual(restarted.generation, snapshots[0].generation)
        XCTAssertEqual(broker.diagnostics.recordCount, 128)
        try broker.removeOwner(owners[0])
        let replacementOwner = try broker.registerOwner(pluginID: "com.example.overflow")
        _ = try broker.start(owner: replacementOwner, id: "focus", durationMilliseconds: 1_000)
        XCTAssertEqual(broker.diagnostics.ownerCount, 128)
        XCTAssertEqual(broker.diagnostics.recordCount, 128)
        XCTAssertEqual(try broker.get(owner: owners[1], id: "focus"), snapshots[1])
    }

    func testCompletionRemainsPendingWithoutListenerAndGetDoesNotDiscardIt() throws {
        let clock = CountdownBrokerClock()
        let broker = makeBroker(clock)
        defer { broker.shutdown() }
        let probe = CountdownBrokerCompletionProbe()
        let owner = try broker.registerOwner(pluginID: "com.example.clock")
        let started = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        clock.now = .seconds(2)
        let completed = try XCTUnwrap(broker.get(owner: owner, id: "focus"))
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.remaining, .zero)
        broker.processDue()
        try observe(broker, owner: owner, probe: probe)
        XCTAssertEqual(probe.events.map(\.generation), [started.generation])
        XCTAssertEqual(probe.events.first?.snapshot, completed)
        try observe(broker, owner: owner, probe: probe)
        broker.processDue()
        XCTAssertEqual(probe.events.count, 1)
    }

    func testObserverTokensCannotRemoveReplacementAndSessionRemovalKeepsBusinessRecord() throws {
        let clock = CountdownBrokerClock()
        let broker = makeBroker(clock)
        defer { broker.shutdown() }
        let oldProbe = CountdownBrokerCompletionProbe()
        let currentProbe = CountdownBrokerCompletionProbe()
        let resumedProbe = CountdownBrokerCompletionProbe()
        let owner = try broker.registerOwner(pluginID: "com.example.clock")
        let oldToken = try broker.observeCompletions(owner: owner) { oldProbe.receive($0) }
        let currentToken = try broker.observeCompletions(owner: owner) { currentProbe.receive($0) }
        try broker.removeCompletionObserver(owner: owner, token: oldToken)
        _ = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        clock.now = .seconds(1)
        broker.processDue()
        XCTAssertTrue(oldProbe.events.isEmpty)
        XCTAssertEqual(currentProbe.events.count, 1)

        let restarted = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        try broker.suspendOwner(owner)
        try broker.removeCompletionObserver(owner: owner, token: currentToken)
        clock.now = .seconds(3)
        try broker.reactivateOwner(owner)
        XCTAssertEqual(try broker.get(owner: owner, id: "focus")?.state, .completed)
        XCTAssertEqual(currentProbe.events.count, 1)
        try observe(broker, owner: owner, probe: resumedProbe)
        XCTAssertEqual(resumedProbe.events.map(\.generation), [restarted.generation])
        XCTAssertEqual(broker.diagnostics.recordCount, 1)

        let replacement = try broker.replaceOwner(owner)
        let replacementProbe = CountdownBrokerCompletionProbe()
        try observe(broker, owner: replacement, probe: replacementProbe)
        assertError(.inactiveOwner) { try broker.removeCompletionObserver(owner: owner, token: currentToken) }
        _ = try broker.start(owner: replacement, id: "focus", durationMilliseconds: 1_000)
        clock.now = .seconds(4)
        broker.processDue()
        XCTAssertEqual(replacementProbe.events.count, 1)
    }

    func testGenerationRoundTripsCanonicalOpaqueValueAndForeignGenerationCannotMutate() throws {
        let clock = CountdownBrokerClock()
        let broker = makeBroker(clock)
        defer { broker.shutdown() }
        let owner = try broker.registerOwner(pluginID: "com.example.clock")
        let started = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        XCTAssertEqual(PluginCountdownGeneration(rawValue: started.generation.rawValue), started.generation)
        for value in ["", "1", "not-a-generation", started.generation.rawValue.uppercased(),
                      "{" + started.generation.rawValue + "}"] {
            XCTAssertNil(PluginCountdownGeneration(rawValue: value))
        }
        let foreign = try XCTUnwrap(PluginCountdownGeneration(rawValue: UUID().uuidString.lowercased()))
        assertError(.staleGeneration) { try broker.stop(owner: owner, id: "focus", generation: foreign) }
        XCTAssertEqual(try broker.get(owner: owner, id: "focus"), started)
    }

    func testUnacknowledgedOfferSurvivesObserverReplacementAndOldTokenCannotAcknowledge() throws {
        let clock = CountdownBrokerClock()
        let broker = makeBroker(clock)
        defer { broker.shutdown() }
        let owner = try broker.registerOwner(pluginID: "com.example.clock")
        let oldProbe = CountdownBrokerCompletionProbe()
        let newProbe = CountdownBrokerCompletionProbe()
        let oldToken = try broker.observeCompletions(owner: owner) { oldProbe.receive($0) }
        let started = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        clock.now = .seconds(1)
        broker.processDue()
        XCTAssertEqual(oldProbe.events.count, 1)
        _ = try broker.get(owner: owner, id: "focus")
        broker.processDue()
        XCTAssertEqual(oldProbe.events.count, 1, "An in-flight offer must suppress reentrant duplicates.")

        let newToken = try broker.observeCompletions(owner: owner) { newProbe.receive($0) }
        XCTAssertEqual(newProbe.events.map(\.generation), [started.generation])
        XCTAssertFalse(try broker.acknowledgeCompletion(owner: owner, id: "focus",
                                                       generation: started.generation, observerToken: oldToken))
        XCTAssertTrue(try broker.acknowledgeCompletion(owner: owner, id: "focus",
                                                      generation: started.generation, observerToken: newToken))
        XCTAssertFalse(try broker.acknowledgeCompletion(owner: owner, id: "focus",
                                                       generation: started.generation, observerToken: newToken))
        _ = try broker.observeCompletions(owner: owner) { newProbe.receive($0) }
        _ = try broker.get(owner: owner, id: "focus")
        XCTAssertEqual(newProbe.events.count, 1, "Acknowledged completion must not replay to a new observer.")
    }

    func testRejectedOfferCanRetryOnLaterGetWithoutImmediateRecursiveDelivery() throws {
        let clock = CountdownBrokerClock()
        let broker = makeBroker(clock)
        defer { broker.shutdown() }
        let owner = try broker.registerOwner(pluginID: "com.example.clock")
        let probe = CountdownBrokerCompletionProbe()
        let token = try broker.observeCompletions(owner: owner) { probe.receive($0) }
        let started = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        clock.now = .seconds(1)
        broker.processDue()
        XCTAssertEqual(probe.events.count, 1)
        XCTAssertTrue(try broker.releaseCompletionOffer(owner: owner, id: "focus",
                                                       generation: started.generation, observerToken: token))
        XCTAssertEqual(probe.events.count, 1)
        _ = try broker.get(owner: owner, id: "focus")
        XCTAssertEqual(probe.events.count, 2)
        XCTAssertTrue(try broker.acknowledgeCompletion(owner: owner, id: "focus",
                                                      generation: started.generation, observerToken: token))
        XCTAssertFalse(try broker.releaseCompletionOffer(owner: owner, id: "focus",
                                                        generation: started.generation, observerToken: token))
        _ = try broker.get(owner: owner, id: "focus")
        XCTAssertEqual(probe.events.count, 2)
    }

    func testSuspendBeforeAcknowledgementRetainsCompletionForNewSession() throws {
        let clock = CountdownBrokerClock()
        let broker = makeBroker(clock)
        defer { broker.shutdown() }
        let owner = try broker.registerOwner(pluginID: "com.example.clock")
        let oldProbe = CountdownBrokerCompletionProbe()
        let newProbe = CountdownBrokerCompletionProbe()
        let oldToken = try broker.observeCompletions(owner: owner) { oldProbe.receive($0) }
        let started = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        clock.now = .seconds(1)
        broker.processDue()
        try broker.suspendOwner(owner)
        assertError(.inactiveOwner) {
            try broker.acknowledgeCompletion(owner: owner, id: "focus",
                                             generation: started.generation, observerToken: oldToken)
        }
        try broker.removeCompletionObserver(owner: owner, token: oldToken)
        try broker.reactivateOwner(owner)
        let newToken = try broker.observeCompletions(owner: owner) { newProbe.receive($0) }
        XCTAssertEqual(oldProbe.events.count, 1)
        XCTAssertEqual(newProbe.events.map(\.generation), [started.generation])
        XCTAssertTrue(try broker.acknowledgeCompletion(owner: owner, id: "focus",
                                                      generation: started.generation, observerToken: newToken))
    }

    func testOldAcknowledgementAndReleaseCannotAffectRestartOrOwnerReplacement() throws {
        let clock = CountdownBrokerClock()
        let broker = makeBroker(clock)
        defer { broker.shutdown() }
        let owner = try broker.registerOwner(pluginID: "com.example.clock")
        let probe = CountdownBrokerCompletionProbe()
        let token = try broker.observeCompletions(owner: owner) { probe.receive($0) }
        let first = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        clock.now = .seconds(1)
        broker.processDue()
        let second = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        assertError(.staleGeneration) {
            try broker.acknowledgeCompletion(owner: owner, id: "focus", generation: first.generation, observerToken: token)
        }
        assertError(.staleGeneration) {
            try broker.releaseCompletionOffer(owner: owner, id: "focus", generation: first.generation, observerToken: token)
        }
        clock.now = .seconds(2)
        broker.processDue()
        XCTAssertTrue(try broker.acknowledgeCompletion(owner: owner, id: "focus",
                                                      generation: second.generation, observerToken: token))
        let replacementOwner = try broker.replaceOwner(owner)
        let replacement = try broker.start(owner: replacementOwner, id: "focus", durationMilliseconds: 1_000)
        assertError(.inactiveOwner) {
            try broker.acknowledgeCompletion(owner: owner, id: "focus", generation: second.generation, observerToken: token)
        }
        assertError(.inactiveOwner) {
            try broker.releaseCompletionOffer(owner: owner, id: "focus", generation: second.generation, observerToken: token)
        }
        XCTAssertEqual(try broker.get(owner: replacementOwner, id: "focus"), replacement)
    }

    func testClearRecordKeepsOwnerAndObserverButStaleOwnerCannotClearReplacement() throws {
        let clock = CountdownBrokerClock()
        let broker = makeBroker(clock)
        defer { broker.shutdown() }
        let probe = CountdownBrokerCompletionProbe()
        let owner = try broker.registerOwner(pluginID: "com.example.clock")
        _ = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        clock.now = .seconds(1)
        XCTAssertEqual(try broker.get(owner: owner, id: "focus")?.state, .completed)
        try broker.clearRecord(owner: owner)
        try observe(broker, owner: owner, probe: probe)
        XCTAssertTrue(probe.events.isEmpty)
        XCTAssertEqual(broker.diagnostics.ownerCount, 1)
        XCTAssertEqual(broker.diagnostics.recordCount, 0)

        _ = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        try broker.clearRecord(owner: owner)
        let surviving = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        clock.now = .seconds(2)
        broker.processDue()
        XCTAssertEqual(probe.events.map(\.generation), [surviving.generation])

        let replacementOwner = try broker.replaceOwner(owner)
        let replacement = try broker.start(owner: replacementOwner, id: "focus", durationMilliseconds: 1_000)
        assertError(.inactiveOwner) { try broker.clearRecord(owner: owner) }
        XCTAssertEqual(try broker.get(owner: replacementOwner, id: "focus"), replacement)
    }

    func testCompletionCanReenterPumpAndRestartSameIDWithoutOldCleanupOverwritingNewRecord() throws {
        let clock = CountdownBrokerClock()
        let probe = CountdownBrokerCompletionProbe()
        let broker = makeBroker(clock)
        defer { broker.shutdown() }
        let owner = try broker.registerOwner(pluginID: "com.example.clock")
        try observe(broker, owner: owner, probe: probe)
        let original = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        probe.handler = { [weak broker, weak probe] _ in
            guard let broker, let probe, probe.events.count == 1 else { return }
            broker.processDue()
            probe.attempt { try broker.start(owner: owner, id: "focus", durationMilliseconds: 2_000) }
        }
        clock.now = .seconds(1)
        broker.processDue()
        XCTAssertTrue(probe.failures.isEmpty)
        XCTAssertEqual(probe.events.map(\.generation), [original.generation])
        let replacement = try XCTUnwrap(broker.get(owner: owner, id: "focus"))
        XCTAssertEqual(replacement.state, .running)
        XCTAssertNotEqual(replacement.generation, original.generation)
        XCTAssertEqual(broker.diagnostics.nextDeadline, Duration.seconds(3))
        clock.now = .seconds(3)
        broker.processDue()
        XCTAssertEqual(probe.events.map(\.generation), [original.generation, replacement.generation])
    }

    func testCompletionReplacingAnotherDueOwnerSkipsItsOldPendingCallback() throws {
        let clock = CountdownBrokerClock()
        let probe = CountdownBrokerCompletionProbe()
        let broker = makeBroker(clock)
        defer { broker.shutdown() }
        let alpha = try broker.registerOwner(pluginID: "com.example.alpha")
        let beta = try broker.registerOwner(pluginID: "com.example.beta")
        try observe(broker, owner: alpha, probe: probe)
        try observe(broker, owner: beta, probe: probe)
        _ = try broker.start(owner: alpha, id: "focus", durationMilliseconds: 1_000)
        let oldBeta = try broker.start(owner: beta, id: "focus", durationMilliseconds: 1_000)
        probe.handler = { [weak broker, weak probe] event in
            guard let broker, let probe, event.owner == alpha else { return }
            probe.attempt {
                let replacement = try broker.replaceOwner(beta)
                try broker.observeCompletions(owner: replacement) { probe.receive($0) }
                return try broker.start(owner: replacement, id: "focus", durationMilliseconds: 1_000)
            }
        }
        clock.now = .seconds(1)
        broker.processDue()
        XCTAssertTrue(probe.failures.isEmpty)
        XCTAssertEqual(probe.events.map(\.owner), [alpha])
        clock.now = .seconds(2)
        broker.processDue()
        XCTAssertEqual(probe.events.count, 2)
        XCTAssertEqual(probe.events.last?.owner.pluginID, beta.pluginID)
        XCTAssertNotEqual(probe.events.last?.owner, beta)
        XCTAssertNotEqual(probe.events.last?.generation, oldBeta.generation)
    }

    func testGetAfterReentrantRestartUsesCurrentClockForReplacementSnapshot() throws {
        let clock = CountdownBrokerClock()
        let probe = CountdownBrokerCompletionProbe()
        let broker = makeBroker(clock)
        defer { broker.shutdown() }
        let owner = try broker.registerOwner(pluginID: "com.example.clock")
        try observe(broker, owner: owner, probe: probe)
        _ = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        probe.handler = { [weak broker, weak probe] _ in
            guard let broker, let probe, probe.events.count == 1 else { return }
            clock.now = .seconds(5)
            probe.attempt { try broker.start(owner: owner, id: "focus", durationMilliseconds: 2_000) }
        }
        clock.now = .seconds(1)
        let replacement = try XCTUnwrap(broker.get(owner: owner, id: "focus"))
        XCTAssertTrue(probe.failures.isEmpty)
        XCTAssertEqual(replacement.state, .running)
        XCTAssertEqual(replacement.remaining, .seconds(2))
        XCTAssertEqual(broker.diagnostics.nextDeadline, Duration.seconds(7))
    }

    func testCompletionShutdownPreventsOtherDueCallbacksAndClearsAllRecords() throws {
        let clock = CountdownBrokerClock()
        let probe = CountdownBrokerCompletionProbe()
        let broker = makeBroker(clock)
        let alpha = try broker.registerOwner(pluginID: "com.example.alpha")
        let beta = try broker.registerOwner(pluginID: "com.example.beta")
        try observe(broker, owner: alpha, probe: probe)
        try observe(broker, owner: beta, probe: probe)
        _ = try broker.start(owner: alpha, id: "focus", durationMilliseconds: 1_000)
        _ = try broker.start(owner: beta, id: "focus", durationMilliseconds: 1_000)
        probe.handler = { [weak broker] _ in broker?.shutdown() }
        clock.now = .seconds(1)
        broker.processDue()
        XCTAssertEqual(probe.events.map(\.owner), [alpha])
        XCTAssertEqual(broker.diagnostics.ownerCount, 0)
        XCTAssertEqual(broker.diagnostics.recordCount, 0)
        XCTAssertEqual(broker.diagnostics.alarmCount, 0)
        assertError(.inactiveOwner) { try broker.registerOwner(pluginID: "com.example.new") }
        assertError(.inactiveOwner) { try broker.get(owner: alpha, id: "focus") }
    }

    func testAutomaticNearestAlarmCancelsOldWakeAndProtectsRestartedGeneration() async throws {
        let clock = CountdownBrokerClock()
        let probe = CountdownBrokerCompletionProbe()
        let sleeper = CountdownBrokerControlledSleeper()
        let broker = makeBroker(clock, automaticScheduling: true, sleeper: sleeper)
        defer { broker.shutdown(); sleeper.releaseAll() }
        let alpha = try broker.registerOwner(pluginID: "com.example.alpha")
        let beta = try broker.registerOwner(pluginID: "com.example.beta")
        try observe(broker, owner: alpha, probe: probe)
        try observe(broker, owner: beta, probe: probe)
        _ = try broker.start(owner: alpha, id: "focus", durationMilliseconds: 10_000)
        try await waitUntil { sleeper.requests.count == 1 }
        _ = try broker.start(owner: beta, id: "focus", durationMilliseconds: 5_000)
        try await waitUntil { sleeper.requests.count == 2 }
        XCTAssertEqual(broker.diagnostics.alarmCount, 1)
        XCTAssertEqual(broker.diagnostics.nextDeadline, Duration.seconds(5))
        clock.now = .seconds(2)
        sleeper.release(0)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(probe.events.isEmpty)
        let betaReplacement = try broker.start(owner: beta, id: "focus", durationMilliseconds: 20_000)
        try await waitUntil { sleeper.requests.count == 3 }
        XCTAssertEqual(broker.diagnostics.nextDeadline, Duration.seconds(10))
        clock.now = .seconds(5)
        sleeper.release(1)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(probe.events.isEmpty)
        XCTAssertEqual(broker.diagnostics.alarmCount, 1)
        XCTAssertEqual(try broker.get(owner: beta, id: "focus")?.generation, betaReplacement.generation)
        clock.now = .seconds(10)
        sleeper.release(2)
        try await waitUntil { sleeper.requests.count == 4 }
        XCTAssertEqual(probe.events.map(\.owner), [alpha])
        XCTAssertEqual(broker.diagnostics.nextDeadline, Duration.seconds(22))
        clock.now = .seconds(22)
        sleeper.release(3)
        try await waitUntil { probe.events.count == 2 }
        XCTAssertEqual(probe.events.last?.generation, betaReplacement.generation)
        XCTAssertEqual(broker.diagnostics.alarmCount, 0)
        XCTAssertNil(broker.diagnostics.nextDeadline)
    }

    func testAutomaticSuspendReactivationAndShutdownLeaveNoIdleAlarmOrLateCompletion() async throws {
        let clock = CountdownBrokerClock()
        let probe = CountdownBrokerCompletionProbe()
        let sleeper = CountdownBrokerControlledSleeper()
        let broker = makeBroker(clock, automaticScheduling: true, sleeper: sleeper)
        defer { broker.shutdown(); sleeper.releaseAll() }
        let owner = try broker.registerOwner(pluginID: "com.example.clock")
        try observe(broker, owner: owner, probe: probe)
        _ = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        try await waitUntil { sleeper.requests.count == 1 }
        try broker.suspendOwner(owner)
        XCTAssertEqual(broker.diagnostics.alarmCount, 0)
        XCTAssertNil(broker.diagnostics.nextDeadline)
        clock.now = .seconds(2)
        sleeper.release(0)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(probe.events.isEmpty)
        try broker.reactivateOwner(owner)
        XCTAssertEqual(probe.events.count, 1)
        XCTAssertEqual(broker.diagnostics.alarmCount, 0)
        _ = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        try await waitUntil { sleeper.requests.count == 2 }
        broker.shutdown()
        clock.now = .seconds(86_400)
        sleeper.release(1)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(probe.events.count, 1)
        XCTAssertEqual(broker.diagnostics.ownerCount, 0)
        XCTAssertEqual(broker.diagnostics.recordCount, 0)
        XCTAssertEqual(broker.diagnostics.alarmCount, 0)
        XCTAssertNil(broker.diagnostics.nextDeadline)
        assertError(.inactiveOwner) { try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000) }
    }

    private func makeBroker(_ clock: CountdownBrokerClock, automaticScheduling: Bool = false,
                            sleeper: CountdownBrokerControlledSleeper? = nil) -> PluginCountdownBroker {
        PluginCountdownBroker(clock: { clock.now }, automaticScheduling: automaticScheduling,
                              sleep: { duration in
                                  if let sleeper { try await sleeper.sleep(duration) }
                                  else { try await Task.sleep(for: duration, clock: .continuous) }
                              })
    }

    private func observe(_ broker: PluginCountdownBroker, owner: PluginCountdownOwner,
                         probe: CountdownBrokerCompletionProbe) throws {
        let receipt = CountdownBrokerObservationReceipt()
        let token = try broker.observeCompletions(owner: owner) { [weak broker] completion in
            probe.receive(completion)
            if let token = receipt.token {
                _ = try? broker?.acknowledgeCompletion(owner: owner, id: completion.id,
                                                       generation: completion.generation, observerToken: token)
            } else { receipt.pending = completion }
        }
        receipt.token = token
        if let pending = receipt.pending {
            _ = try? broker.acknowledgeCompletion(owner: owner, id: pending.id,
                                                generation: pending.generation, observerToken: token)
        }
    }

    private func assertError<T>(_ expected: PluginCountdownError, file: StaticString = #filePath, line: UInt = #line,
                                _ operation: () throws -> T) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? PluginCountdownError, expected, file: file, line: line)
        }
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                XCTFail("The controlled Host alarm did not settle.")
                throw CountdownBrokerTestError.timedOut
            }
            await Task.yield()
        }
    }
}

@MainActor
private final class CountdownBrokerClock {
    var now: Duration = .zero
}

@MainActor
private final class CountdownBrokerCompletionProbe {
    var events: [PluginCountdownCompletion] = []
    var failures: [String] = []
    var handler: (@MainActor @Sendable (PluginCountdownCompletion) -> Void)?

    func receive(_ completion: PluginCountdownCompletion) {
        events.append(completion)
        handler?(completion)
    }

    func attempt<T>(_ operation: () throws -> T) {
        do { _ = try operation() }
        catch { failures.append(String(describing: error)) }
    }
}

@MainActor
private final class CountdownBrokerObservationReceipt {
    var token: UUID?
    var pending: PluginCountdownCompletion?
}

/// Deliberately ignores cancellation until released, modelling an obsolete
/// alarm completion already queued when the broker changes its generation.
@MainActor
private final class CountdownBrokerControlledSleeper {
    private(set) var requests: [Duration] = []
    private var continuations: [Int: CheckedContinuation<Void, any Error>] = [:]

    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let id = requests.count
            requests.append(duration)
            continuations[id] = continuation
        }
    }

    func release(_ id: Int) { continuations.removeValue(forKey: id)?.resume() }
    func releaseAll() {
        let pending = Array(continuations.values)
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private enum CountdownBrokerTestError: Error { case timedOut }
