import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginCountdownDisplayObservationTests: XCTestCase {
    func testBusinessMutationsCoalesceAndReadOrRejectedCommandsDoNotInvalidate() async throws {
        let broker = PluginCountdownBroker(automaticScheduling: false)
        defer { broker.shutdown() }
        let counter = CountdownInvalidationCounter()
        let token = broker.observeChanges { counter.value += 1 }
        let owner = try broker.registerOwner(pluginID: "com.example.display-observation")
        let started = try broker.start(owner: owner, id: "focus", durationMilliseconds: 60_000)
        let paused = try broker.pause(owner: owner, id: "focus", generation: started.generation)
        let resumed = try broker.resume(owner: owner, id: "focus", generation: paused.generation)
        XCTAssertEqual(counter.value, 0, "Mutation callbacks must finish before display invalidation")
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(counter.value, 1)
        _ = broker.snapshotForDisplay(owner: owner, id: "focus", generation: resumed.generation)
        _ = try broker.get(owner: owner, id: "focus")
        XCTAssertThrowsError(try broker.pause(owner: owner, id: "focus", generation: started.generation))
        XCTAssertThrowsError(try broker.start(owner: owner, id: "other", durationMilliseconds: 1_000))
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(counter.value, 1, "A plugin cannot force display pulses by rejected commands")
        broker.removeChangeObserver(token)
        try broker.stop(owner: owner, id: "focus", generation: resumed.generation)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(counter.value, 1)
    }

    func testShutdownCancelsPendingDisplayInvalidation() async throws {
        let broker = PluginCountdownBroker(automaticScheduling: false)
        let counter = CountdownInvalidationCounter()
        _ = broker.observeChanges { counter.value += 1 }
        let owner = try broker.registerOwner(pluginID: "com.example.display-shutdown")
        _ = try broker.start(owner: owner, id: "focus", durationMilliseconds: 1_000)
        broker.shutdown()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(counter.value, 0)
    }
}

@MainActor
private final class CountdownInvalidationCounter { var value = 0 }
