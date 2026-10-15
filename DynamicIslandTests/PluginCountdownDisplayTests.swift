import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginCountdownDisplayTests: XCTestCase {
    func testDisplayDeadlineProjectionDoesNotOfferCompletionOrMutateBusinessState() throws {
        let clock = CountdownDisplayTestClock()
        let broker = PluginCountdownBroker(clock: { clock.now }, automaticScheduling: false)
        defer { broker.shutdown() }
        let owner = try broker.registerOwner(pluginID: "com.example.display")
        let capture = CountdownDisplayCompletionCapture()
        let observer = try broker.observeCompletions(owner: owner) { capture.events.append($0) }
        let started = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        let initialDiagnostics = broker.diagnostics

        clock.now = .seconds(1) - .nanoseconds(1)
        let before = try XCTUnwrap(broker.snapshotForDisplay(owner: owner, id: "focus", generation: started.generation))
        XCTAssertEqual(before.state, .running)
        XCTAssertEqual(before.remaining, .nanoseconds(1))
        clock.now = .seconds(1)
        let projected = try XCTUnwrap(broker.snapshotForDisplay(owner: owner, id: "focus", generation: started.generation))
        XCTAssertEqual(projected.state, .completed)
        XCTAssertEqual(projected.remaining, .zero)
        clock.now = .seconds(2)
        XCTAssertEqual(broker.snapshotForDisplay(owner: owner, id: "focus", generation: started.generation), projected)
        XCTAssertTrue(capture.events.isEmpty)
        XCTAssertEqual(broker.diagnostics, initialDiagnostics)

        broker.processDue()
        XCTAssertEqual(capture.events.count, 1)
        XCTAssertEqual(capture.events.first?.snapshot, projected)
        XCTAssertTrue(try broker.acknowledgeCompletion(owner: owner, id: "focus",
                                                      generation: started.generation, observerToken: observer))
        _ = broker.snapshotForDisplay(owner: owner, id: "focus", generation: started.generation)
        broker.processDue()
        XCTAssertEqual(capture.events.count, 1)
        XCTAssertEqual(broker.diagnostics.completedCount, 1)
    }

    func testDisplayRejectsStaleOwnerGenerationForeignIDAndSuspendedOwner() throws {
        let clock = CountdownDisplayTestClock()
        let broker = PluginCountdownBroker(clock: { clock.now }, automaticScheduling: false)
        defer { broker.shutdown() }
        let owner = try broker.registerOwner(pluginID: "com.example.display")
        let foreignOwner = try broker.registerOwner(pluginID: "com.example.foreign")
        let original = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        let foreign = try broker.start(owner: foreignOwner, id: "focus", durationMilliseconds: 1_000)
        XCTAssertNil(broker.snapshotForDisplay(owner: owner, id: "other", generation: original.generation))
        XCTAssertNil(broker.snapshotForDisplay(owner: owner, id: "focus", generation: foreign.generation))
        XCTAssertNil(broker.snapshotForDisplay(owner: foreignOwner, id: "focus", generation: original.generation))
        let restarted = try broker.start(owner: owner, id: "focus", durationMilliseconds: 2_000)
        XCTAssertNil(broker.snapshotForDisplay(owner: owner, id: "focus", generation: original.generation))
        XCTAssertEqual(broker.snapshotForDisplay(owner: owner, id: "focus", generation: restarted.generation), restarted)

        let replacementOwner = try broker.replaceOwner(owner)
        let replacement = try broker.start(owner: replacementOwner, id: "focus", durationMilliseconds: 1_000)
        XCTAssertNil(broker.snapshotForDisplay(owner: owner, id: "focus", generation: restarted.generation))
        try broker.suspendOwner(replacementOwner)
        XCTAssertNil(broker.snapshotForDisplay(owner: replacementOwner, id: "focus", generation: replacement.generation))
        try broker.reactivateOwner(replacementOwner)
        XCTAssertEqual(broker.snapshotForDisplay(owner: replacementOwner, id: "focus", generation: replacement.generation), replacement)
    }

    func testPausedDisplayKeepsExactRemainingAndResumeRejectsPreviousGeneration() throws {
        let clock = CountdownDisplayTestClock()
        let broker = PluginCountdownBroker(clock: { clock.now }, automaticScheduling: false)
        defer { broker.shutdown() }
        let owner = try broker.registerOwner(pluginID: "com.example.display")
        let started = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_001)
        clock.now = .nanoseconds(123_456_789)
        let paused = try broker.pause(owner: owner, id: "focus", generation: started.generation)
        let remaining = Duration.milliseconds(1_001) - .nanoseconds(123_456_789)
        XCTAssertEqual(paused.remaining, remaining)
        XCTAssertNil(broker.snapshotForDisplay(owner: owner, id: "focus", generation: started.generation))
        clock.now = .seconds(86_400)
        let diagnostics = broker.diagnostics
        XCTAssertEqual(broker.snapshotForDisplay(owner: owner, id: "focus", generation: paused.generation), paused)
        XCTAssertEqual(broker.diagnostics, diagnostics)

        let resumed = try broker.resume(owner: owner, id: "focus", generation: paused.generation)
        XCTAssertNil(broker.snapshotForDisplay(owner: owner, id: "focus", generation: paused.generation))
        XCTAssertEqual(broker.snapshotForDisplay(owner: owner, id: "focus", generation: resumed.generation)?.remaining, remaining)
        clock.now += remaining - .nanoseconds(1)
        let before = try XCTUnwrap(broker.snapshotForDisplay(owner: owner, id: "focus", generation: resumed.generation))
        XCTAssertEqual(before.state, .running)
        XCTAssertEqual(before.remaining, .nanoseconds(1))
    }

    func testInvalidClockReturnsNoDisplaySnapshotAndLeavesRecordUntouched() throws {
        let clock = CountdownDisplayTestClock()
        let broker = PluginCountdownBroker(clock: { clock.now }, automaticScheduling: false)
        defer { broker.shutdown() }
        let owner = try broker.registerOwner(pluginID: "com.example.display")
        let started = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        let diagnostics = broker.diagnostics
        for invalid in [Duration.nanoseconds(-1), .seconds(-1)] {
            clock.now = invalid
            XCTAssertNil(broker.snapshotForDisplay(owner: owner, id: "focus", generation: started.generation))
            XCTAssertEqual(broker.diagnostics, diagnostics)
        }
        clock.now = .zero
        XCTAssertEqual(broker.snapshotForDisplay(owner: owner, id: "focus", generation: started.generation), started)
    }

    func testDisplayFormattingCeilsSecondsAndKeepsExactProgressWithoutPausedOrCompletedTicks() throws {
        let clock = CountdownDisplayTestClock()
        let broker = PluginCountdownBroker(clock: { clock.now }, automaticScheduling: false)
        defer { broker.shutdown() }
        let owner = try broker.registerOwner(pluginID: "com.example.display")
        let hour = try broker.start(owner: owner, id: "focus", durationMilliseconds: 3_600_000)
        XCTAssertEqual(hour.displayText, "1:00:00")
        XCTAssertEqual(hour.elapsedFraction, 0)
        XCTAssertTrue(hour.requiresDisplayTick)
        clock.now = .nanoseconds(1)
        let subsecond = try XCTUnwrap(broker.snapshotForDisplay(owner: owner, id: "focus", generation: hour.generation))
        XCTAssertEqual(subsecond.displayText, "1:00:00")
        XCTAssertGreaterThan(subsecond.elapsedFraction, 0)
        XCTAssertEqual(subsecond.elapsedFraction, 1.0 / 3_600_000_000_000.0, accuracy: 0.000_000_000_000_001)
        clock.now = .seconds(1)
        let second = try XCTUnwrap(broker.snapshotForDisplay(owner: owner, id: "focus", generation: hour.generation))
        XCTAssertEqual(second.displayText, "59:59")
        XCTAssertEqual(second.elapsedFraction, 1.0 / 3_600.0, accuracy: 0.000_000_001)
        let paused = try broker.pause(owner: owner, id: "focus", generation: hour.generation)
        XCTAssertEqual(paused.displayText, "59:59")
        XCTAssertFalse(paused.requiresDisplayTick)

        let finalSecond = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        clock.now = .seconds(2) - .nanoseconds(1)
        let last = try XCTUnwrap(broker.snapshotForDisplay(owner: owner, id: "focus", generation: finalSecond.generation))
        XCTAssertEqual(last.displayText, "00:01")
        XCTAssertTrue(last.requiresDisplayTick)
        clock.now = .seconds(2)
        let completed = try XCTUnwrap(broker.snapshotForDisplay(owner: owner, id: "focus", generation: finalSecond.generation))
        XCTAssertEqual(completed.displayText, "00:00")
        XCTAssertEqual(completed.elapsedFraction, 1)
        XCTAssertFalse(completed.requiresDisplayTick)
    }
}

@MainActor
private final class CountdownDisplayTestClock {
    var now: Duration = .zero
}

@MainActor
private final class CountdownDisplayCompletionCapture {
    var events: [PluginCountdownCompletion] = []
}
