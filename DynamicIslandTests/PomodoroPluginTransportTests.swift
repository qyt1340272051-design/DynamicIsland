import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PomodoroPluginTransportTests: XCTestCase {
    func testBlockedStorageDoesNotRetainRealStartPauseResumeOrActivityReplies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = PomodoroStorageGate()
        let storage = PluginStorage(configuration: .init(rootDirectoryURL: root), ioObserver: { gate.observe() })
        let f = try PomodoroPluginFixture(storage: storage)
        defer { gate.release(); f.shutdown() }
        try f.grantStorage()
        try await f.load()
        gate.arm()
        try f.act("preset.45")
        try await f.waitForState("准备专注", minutes: 45)
        try await f.waitUntil { gate.hasEntered }
        XCTAssertFalse(gate.wasOnMainThread)

        // The real action mints its five-second activation while the Storage
        // actor remains blocked. Neither a Host command nor its render reply
        // may depend on releasing that I/O operation.
        try f.act("start")
        try await f.waitForState("专注中", minutes: 45)
        XCTAssertEqual(try f.record()?.state, .running)
        try f.act("pause")
        try await f.waitForState("已暂停", minutes: 45)
        try f.act("resume")
        try await f.waitForState("专注中", minutes: 45)
        try f.act("stop")
        try await f.waitForState("准备专注", minutes: 45)
        XCTAssertNil(try f.record())
        XCTAssertTrue(gate.isBlocking)
        gate.release()
        try await waitForStoredState(storage, f: f, minutes: 45, state: "idle")
        f.assertNoFailures()
    }

    func testDisableRevokesBlockedWriteWhileInteractiveLaneHasStartedTheTimer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = PomodoroStorageGate()
        let storage = PluginStorage(configuration: .init(rootDirectoryURL: root), ioObserver: { gate.observe() })
        let f = try PomodoroPluginFixture(storage: storage)
        defer { gate.release(); f.shutdown() }
        let baseline = settings(minutes: 25, state: "idle")
        try await storage.set(pluginID: f.id, key: "settings", value: baseline)
        try f.grantStorage()
        try await f.load()
        gate.arm()
        try f.act("preset.60")
        try await f.waitForState("准备专注", minutes: 60)
        try await f.waitUntil { gate.hasEntered }
        try f.act("start")
        try await f.waitForState("专注中", minutes: 60)
        let oldContext = try f.context()
        f.lifecycle.pluginDidChangeEnablement(id: f.id, isEnabled: false)
        XCTAssertThrowsError(try oldContext.perform {})
        XCTAssertEqual(f.broker.diagnostics.recordCount, 0)
        XCTAssertTrue(f.manager.toolSnapshots.isEmpty)
        gate.release()
        let value = try await storage.get(pluginID: f.id, key: "settings")
        XCTAssertEqual(value, baseline)
    }

    func testStorageLaneKeepsSetGetOrderWhileInteractiveRequestsComplete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = PomodoroStorageGate()
        let storage = PluginStorage(configuration: .init(rootDirectoryURL: root), ioObserver: { gate.observe() })
        let f = try PomodoroPluginFixture(storage: storage)
        defer { gate.release(); f.shutdown() }
        try f.grantStorage()
        try await f.load()
        let transport = PluginBridgeTransport(bridge: f.bridge, package: f.package, context: try f.context())
        defer { transport.revoke() }
        let replies = PomodoroTransportReplies()
        gate.arm()
        XCTAssertTrue(transport.submit(id: 1, json: request("storage.set", params: ["key": "ordered", "value": 1])) {
            replies.add($0, $1)
        })
        try await f.waitUntil { gate.hasEntered }
        XCTAssertTrue(transport.submit(id: 2, json: request("storage.get", params: ["key": "ordered"])) {
            replies.add($0, $1)
        })
        XCTAssertTrue(transport.submit(id: 3, json: request("log", params: ["message": "interactive", "level": "info"])) {
            replies.add($0, $1)
        })
        try await f.waitUntil { replies.ids == [3] }
        XCTAssertTrue(gate.isBlocking)
        gate.release()
        try await f.waitUntil { replies.ids.count == 3 }
        XCTAssertEqual(replies.ids, [3, 1, 2])
        let value = try XCTUnwrap(replies.response(2))
        XCTAssertEqual(try PluginBridgeJSON.parse(value), .object(["ok": .boolean(true), "value": .number(1)]))
    }

    func testQueueLimitIsSharedAcrossBothLanesAndRevocationDropsTheirEffects() async throws {
        let f = try PomodoroPluginFixture()
        defer { f.shutdown() }
        try await f.load()
        let transport = PluginBridgeTransport(bridge: f.bridge, package: f.package, context: try f.context())
        let replies = PomodoroTransportReplies()
        // MainActor cannot drain either lane during this synchronous section.
        for index in 0..<64 {
            let json = index.isMultiple(of: 2)
                ? request("storage.get", params: ["key": "queued"])
                : request("log", params: ["message": "queued", "level": "info"])
            XCTAssertTrue(transport.submit(id: index, json: json) { replies.add($0, $1) })
        }
        XCTAssertFalse(transport.submit(id: 64, json: "{}") { replies.add($0, $1) })
        transport.revoke()
        try await f.flushWorker()
        XCTAssertTrue(replies.ids.isEmpty)
        XCTAssertTrue(f.bridge.diagnostics.records(for: f.id).isEmpty)
        XCTAssertFalse(transport.submit(id: 65, json: "{}") { replies.add($0, $1) })
    }

    func testFullQueueReleasesReplySlotBeforeAConsumerImmediatelySubmitsAgain() async throws {
        let f = try PomodoroPluginFixture()
        defer { f.shutdown() }
        try await f.load()
        let transport = PluginBridgeTransport(bridge: f.bridge, package: f.package, context: try f.context())
        defer { transport.revoke() }
        let replies = PomodoroTransportReplies()
        let json = request("log", params: ["message": "bounded", "level": "info"])
        for index in 0..<64 {
            XCTAssertTrue(transport.submit(id: index, json: json) { id, response in
                replies.add(id, response)
                if id == 0 {
                    // Same call stack as delivery, before drain can return.
                    let admitted = transport.submit(id: 64, json: json) { replies.add($0, $1) }
                    replies.add(100, admitted ? "admitted" : "rejected")
                }
            })
        }
        try await f.waitUntil { replies.ids.count == 66 }
        XCTAssertEqual(replies.response(100), "admitted")
        XCTAssertNotNil(replies.response(64))
    }

    private func settings(minutes: Int, state: String) -> PluginBridgeJSON {
        .object(["schemaVersion": .number(1), "selectedMinutes": .number(Double(minutes)), "lastSession": .string(state)])
    }

    private func request(_ method: String, params: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["apiVersion": "1.0.0", "method": method, "params": params]), encoding: .utf8)!
    }

    private func waitForStoredState(_ storage: PluginStorage, f: PomodoroPluginFixture,
                                    minutes: Int, state: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while try await storage.get(pluginID: f.id, key: "settings") != settings(minutes: minutes, state: state) {
            guard ContinuousClock.now < deadline else { XCTFail("Latest settings were not saved"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private nonisolated final class PomodoroTransportReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, String)] = []
    var ids: [Int] { lock.withLock { values.map(\.0) } }
    func add(_ id: Int, _ response: String) { lock.withLock { values.append((id, response)) } }
    func response(_ id: Int) -> String? { lock.withLock { values.first { $0.0 == id }?.1 } }
}

private nonisolated final class PomodoroStorageGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var armed = false
    private var entered = false
    private var released = false
    private var timedOut = false
    private var mainThread = false
    var hasEntered: Bool { lock.withLock { entered } }
    var isBlocking: Bool { lock.withLock { entered && !released && !timedOut } }
    var wasOnMainThread: Bool { lock.withLock { mainThread } }
    func arm() { lock.withLock { armed = true } }
    func observe() {
        let block = lock.withLock {
            guard armed, !entered else { return false }
            entered = true
            mainThread = Thread.isMainThread
            return true
        }
        if block, semaphore.wait(timeout: .now() + 12) == .timedOut {
            lock.withLock { timedOut = true }
        }
    }
    func release() {
        lock.withLock { released = true }
        semaphore.signal()
    }
}
