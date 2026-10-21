import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PomodoroPluginStorageTests: XCTestCase {
    func testDiskSettingsSurviveEntirelyNewStoreAndHostWithoutRestoringRunningRecord() async throws {
        let workspace = try PomodoroStorageWorkspace()
        defer { workspace.remove() }
        let first = try PomodoroPluginFixture(storage: PluginStorage(configuration: workspace.configuration))
        defer { first.shutdown() }
        try first.grantStorage()
        try await first.load()
        try first.act("preset.45")
        try await first.waitForState("准备专注", minutes: 45)
        try await waitForSettings(first, equals: settings(45, "idle"))
        try first.act("start")
        try await first.waitForState("专注中", minutes: 45)
        try await waitForSettings(first, equals: settings(45, "running"))
        let oldOwner = try first.owner()
        first.shutdown()

        let second = try PomodoroPluginFixture(storage: PluginStorage(configuration: workspace.configuration))
        defer { second.shutdown() }
        XCTAssertEqual(try second.permissions.state(permission: .localStorage, package: second.package), .requested)
        try second.grantStorage()
        try await second.load(minutes: 45)
        XCTAssertNotEqual(try second.owner(), oldOwner)
        XCTAssertNil(try second.record())
        XCTAssertEqual(second.broker.diagnostics.runningCount, 0)
        XCTAssertFalse(try XCTUnwrap(second.tool).presentation.isCompactVisible)
        XCTAssertTrue(second.references.isEmpty)
        second.assertNoFailures()
    }

    func testAllValidPresetsAndSessionMetadataRestoreSettingsOnly() async throws {
        for (minutes, lastSession) in [(15, "idle"), (25, "running"), (45, "paused"), (60, "completed")] {
            let f = try PomodoroPluginFixture()
            defer { f.shutdown() }
            try await f.storage.set(pluginID: f.id, key: "settings", value: settings(minutes, lastSession))
            try f.grantStorage()
            try await f.load(minutes: minutes)
            try await f.flushWorker()
            XCTAssertFalse(f.hasUnsavedSettingsHint)
            XCTAssertNil(try f.record())
            XCTAssertEqual(f.broker.diagnostics.recordCount, 0)
            XCTAssertTrue(f.references.isEmpty)
            XCTAssertFalse(try XCTUnwrap(f.tool).presentation.isCompactVisible)
            f.assertNoFailures()
        }
    }

    func testPresetActionsAndBusinessTransitionsSaveOnlyTheVersionedMetadata() async throws {
        let f = try PomodoroPluginFixture()
        defer { f.shutdown() }
        try f.grantStorage()
        try await f.load()
        try f.act("preset.15")
        try await f.waitForState("准备专注", minutes: 15)
        try await waitForSettings(f, equals: settings(15, "idle"))
        try f.act("start")
        try await f.waitForState("专注中", minutes: 15)
        try await waitForSettings(f, equals: settings(15, "running"))
        f.clock.now += .nanoseconds(123)
        try f.act("pause")
        try await f.waitForState("已暂停", minutes: 15)
        try await waitForSettings(f, equals: settings(15, "paused"))
        let paused = try XCTUnwrap(try f.record())
        try f.act("resume")
        try await f.waitForState("专注中", minutes: 15)
        try await waitForSettings(f, equals: settings(15, "running"))
        XCTAssertEqual(try f.record()?.remaining, paused.remaining)
        f.clock.now += paused.remaining
        f.broker.processDue()
        try await f.waitForState("本轮已完成", minutes: 15)
        try await waitForSettings(f, equals: settings(15, "completed"))
        try await f.waitUntil { f.manager.activity(id: f.completionID) != nil }
        f.activityClock.advance(by: 3)
        f.manager.processDeadlines()
        try f.act("stop")
        try await f.waitForState("准备专注", minutes: 15)
        try await waitForSettings(f, equals: settings(15, "idle"))
        // The Storage actor exposes the new value before the JavaScript
        // Promise completion queues and publishes its cleared save hint.
        // Observe that separate public UI commit instead of racing it.
        try await f.waitUntil {
            f.tool?.presentation.subtitle == "15 分钟 · 准备专注" && !f.hasUnsavedSettingsHint
        }
        XCTAssertNil(try f.record())
        XCTAssertFalse(f.hasUnsavedSettingsHint)
        f.assertNoFailures()
    }

    func testMalformedSettingsFailClosedToTwentyFiveWithoutStartingOrOverwriting() async throws {
        let valid = fields(45, "idle")
        var missing = valid
        missing.removeValue(forKey: "lastSession")
        var unknown = valid
        unknown["deadline"] = .number(123)
        var badVersion = valid
        badVersion["schemaVersion"] = .number(2)
        var versionType = valid
        versionType["schemaVersion"] = .string("1")
        var badPreset = valid
        badPreset["selectedMinutes"] = .number(30)
        var presetType = valid
        presetType["selectedMinutes"] = .string("45")
        var fractionalPreset = valid
        fractionalPreset["selectedMinutes"] = .number(25.5)
        var badSession = valid
        badSession["lastSession"] = .string("resuming")
        var sessionType = valid
        sessionType["lastSession"] = .boolean(false)
        let invalid: [PluginBridgeJSON] = [
            .boolean(true), .string("settings"), .array([.object(valid)]),
            .object(missing), .object(unknown), .object(badVersion), .object(versionType),
            .object(badPreset), .object(presetType), .object(fractionalPreset),
            .object(badSession), .object(sessionType)
        ]
        for value in invalid {
            let f = try PomodoroPluginFixture()
            defer { f.shutdown() }
            try await f.storage.set(pluginID: f.id, key: "settings", value: value)
            try f.grantStorage()
            try await f.load()
            try await f.waitUntil { f.hasUnsavedSettingsHint }
            XCTAssertNil(try f.record())
            XCTAssertTrue(f.references.isEmpty)
            let stored = try await f.storage.get(pluginID: f.id, key: "settings")
            XCTAssertEqual(stored, value, "Invalid settings must not be silently replaced before a user action.")
            f.assertNoFailures()
        }
    }

    func testRequestedDeniedAndRevokedStorageNeverReachDiskOrBlockTimerActions() async throws {
        let cases: [(PluginPermissionDecision?, PluginPermissionState)] = [
            (nil, .requested), (.denied, .denied), (.revoked, .revoked)
        ]
        for (decision, state) in cases {
            let workspace = try PomodoroStorageWorkspace()
            defer { workspace.remove() }
            let io = PomodoroStorageIOCounter()
            let storage = PluginStorage(configuration: workspace.configuration, ioObserver: { io.record() })
            let f = try PomodoroPluginFixture(storage: storage)
            defer { f.shutdown() }
            let untouched = settings(45, "completed")
            try await storage.set(pluginID: f.id, key: "settings", value: untouched)
            let baseline = io.count
            if let decision { try f.decideStorage(decision) }
            try await f.load()
            try await f.waitUntil { f.hasUnsavedSettingsHint }
            XCTAssertEqual(try f.permissions.state(permission: .localStorage, package: f.package), state)
            try f.act("preset.15")
            try await f.waitForState("准备专注", minutes: 15)
            try f.act("start")
            try await f.waitForState("专注中", minutes: 15)
            XCTAssertEqual(try f.record()?.durationMilliseconds, 15 * 60_000)
            try f.act("pause")
            try await f.waitForState("已暂停", minutes: 15)
            try f.act("resume")
            try await f.waitForState("专注中", minutes: 15)
            try f.act("stop")
            try await f.waitForState("准备专注", minutes: 15)
            try await f.flushWorker()
            XCTAssertNil(try f.record())
            XCTAssertTrue(f.hasUnsavedSettingsHint)
            XCTAssertEqual(io.count, baseline, "An ungranted plugin must not reach the Storage I/O actor.")
            let stored = try await storage.get(pluginID: f.id, key: "settings")
            XCTAssertEqual(stored, untouched)
            f.assertNoFailures()
        }
    }

    func testRevocationKeepsBusinessWorkingAndRegrantSavesLatestUnsavedSelectionOnNextAction() async throws {
        let f = try PomodoroPluginFixture()
        defer { f.shutdown() }
        try f.grantStorage()
        try await f.load()
        try f.act("preset.45")
        try await f.waitForState("准备专注", minutes: 45)
        try await waitForSettings(f, equals: settings(45, "idle"))
        try f.act("start")
        try await f.waitForState("专注中", minutes: 45)
        try await waitForSettings(f, equals: settings(45, "running"))
        let oldLease = try f.permissions.require(permission: .localStorage, package: f.package)
        try f.revokeStorage()
        XCTAssertThrowsError(try oldLease.perform {})
        try f.act("pause")
        try await f.waitForState("已暂停", minutes: 45)
        try await f.waitUntil { f.hasUnsavedSettingsHint }
        try f.act("preset.60")
        try await f.waitForState("准备专注", minutes: 60)
        XCTAssertNil(try f.record())
        let stale = try await f.storage.get(pluginID: f.id, key: "settings")
        XCTAssertEqual(stale, settings(45, "running"))

        try f.grantStorage()
        try f.act("start")
        try await f.waitForState("专注中", minutes: 60)
        try await waitForSettings(f, equals: settings(60, "running"))
        try await f.waitUntil { !f.hasUnsavedSettingsHint }
        XCTAssertEqual(try f.record()?.durationMilliseconds, 60 * 60_000)
        XCTAssertThrowsError(try oldLease.perform {})
        f.assertNoFailures()
    }

    private func fields(_ minutes: Int, _ state: String) -> [String: PluginBridgeJSON] {
        ["schemaVersion": .number(1), "selectedMinutes": .number(Double(minutes)), "lastSession": .string(state)]
    }

    private func settings(_ minutes: Int, _ state: String) -> PluginBridgeJSON { .object(fields(minutes, state)) }

    private func waitForSettings(_ f: PomodoroPluginFixture, equals expected: PluginBridgeJSON,
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while try await f.storage.get(pluginID: f.id, key: "settings") != expected {
            guard ContinuousClock.now < deadline else {
                XCTFail("Official Pomodoro settings did not reach the expected durable value.", file: file, line: line)
                throw PomodoroStorageTestError.unsettled
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct PomodoroStorageWorkspace {
    let root: URL
    let configuration: PluginStorageConfiguration

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pomodoro-storage-\(UUID().uuidString)",
                                                                           isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        configuration = .init(rootDirectoryURL: root)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private nonisolated final class PomodoroStorageIOCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func record() { lock.lock(); value += 1; lock.unlock() }
}

private enum PomodoroStorageTestError: Error { case unsettled }
