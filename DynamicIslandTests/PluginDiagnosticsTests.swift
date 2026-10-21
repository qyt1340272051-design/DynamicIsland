import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginDiagnosticsTests: XCTestCase {
    func testPerPluginRingKeepsNewest100WithMonotonicSequenceAndInjectedTimestamps() throws {
        let clock = DiagnosticsTestClock()
        let store = PluginDiagnosticsStore(clock: { clock.date })
        for index in 0..<105 {
            clock.date = Date(timeIntervalSinceReferenceDate: Double(index))
            store.recordPluginMessage(pluginID: "com.example.alpha", level: .info)
        }
        let records = store.records(for: "com.example.alpha")
        XCTAssertEqual(records.count, 100)
        XCTAssertEqual(records.map(\.sequence), Array(6...105).map(UInt64.init))
        XCTAssertEqual(records.first?.timestamp, Date(timeIntervalSinceReferenceDate: 5))
        XCTAssertEqual(records.last?.timestamp, Date(timeIntervalSinceReferenceDate: 104))
        XCTAssertTrue(records.allSatisfy { $0.category == .pluginMessage && $0.code == "pluginMessage" && $0.message == "Plugin log message omitted." })
        store.clear(for: "com.example.alpha")
        XCTAssertTrue(store.allRecords().isEmpty)
        store.recordPluginMessage(pluginID: "com.example.beta", level: .warning)
        XCTAssertEqual(store.allRecords().first?.sequence, 106)
        store.clearAll()
        store.recordPluginMessage(pluginID: "com.example.alpha", level: .debug)
        XCTAssertEqual(store.allRecords().first?.sequence, 107)
    }

    func testGlobalRingKeeps1000RecordsAcrossPluginsWithoutExceedingAnyPluginBudget() {
        let store = PluginDiagnosticsStore()
        for plugin in 0..<12 {
            for _ in 0..<100 { store.recordPluginMessage(pluginID: "com.example.p\(plugin)", level: .debug) }
        }
        let records = store.allRecords()
        XCTAssertEqual(records.count, 1_000)
        XCTAssertEqual(records.first?.sequence, 201)
        XCTAssertEqual(records.last?.sequence, 1_200)
        XCTAssertTrue(store.records(for: "com.example.p0").isEmpty)
        XCTAssertTrue(store.records(for: "com.example.p1").isEmpty)
        XCTAssertTrue(Dictionary(grouping: records, by: \.pluginID).values.allSatisfy { $0.count <= 100 })
    }

    func testPluginInventoryEvictsLeastRecentlyUsedIDAndRejectsInvalidIdentifiers() {
        let store = PluginDiagnosticsStore()
        XCTAssertNil(store.recordPluginMessage(pluginID: "/Users/private/token", level: .error))
        XCTAssertNil(store.recordPluginMessage(pluginID: "../clipboard", level: .error))
        XCTAssertTrue(store.allRecords().isEmpty)
        for index in 0..<128 { store.recordPluginMessage(pluginID: "com.example.p\(index)", level: .info) }
        store.recordPluginMessage(pluginID: "com.example.p0", level: .info)
        store.recordPluginMessage(pluginID: "com.example.p128", level: .info)
        XCTAssertEqual(Set(store.allRecords().map(\.pluginID)).count, 128)
        XCTAssertEqual(store.records(for: "com.example.p0").count, 2)
        XCTAssertTrue(store.records(for: "com.example.p1").isEmpty)
        XCTAssertEqual(store.records(for: "com.example.p128").count, 1)
        XCTAssertEqual(store.allRecords().last?.sequence, 130)
    }

    func testRuntimeDiagnosticRetainsOnlyFixedPhaseAndCodeAndDiscardsFailureBody() throws {
        let store = PluginDiagnosticsStore()
        let secret = "Bearer private-token /Users/private/account.txt clipboard-body selected-file-body https://private.example/secret"
        store.recordRuntimeFailure(pluginID: "com.example.alpha",
            failure: .init(phase: .bridge, code: .javaScriptException, message: secret))
        store.recordLifecycleFailure(pluginID: "com.example.alpha", failure: .stopFailed)
        store.recordWatchdogIsolation(pluginID: "com.example.alpha")
        store.recordPersistenceFailure(pluginID: "com.example.alpha")
        let entries = store.allRecords()
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries.first?.phase, .bridge)
        XCTAssertEqual(entries.first?.code, "javaScriptException")
        XCTAssertEqual(entries.first?.message, "Plugin Runtime failed.")
        XCTAssertEqual(entries.map(\.category), [.runtimeFailure, .lifecycleFailure, .watchdogIsolation, .persistenceFailure])
        for fragment in ["private-token", "/Users/private", "clipboard-body", "selected-file-body", "private.example"] {
            XCTAssertFalse(String(reflecting: entries).contains(fragment))
        }
    }

    func testHostObserversSeeCommittedInventoryAndOnlyActualChangesUntilUnregistered() {
        let store = PluginDiagnosticsStore()
        var counts: [Int] = []
        let observer = store.observeChanges { counts.append(store.allRecords().count) }
        store.clearAll()
        store.recordPluginMessage(pluginID: "com.example.alpha", level: .info)
        store.recordPluginMessage(pluginID: "../invalid", level: .error)
        store.clear(for: "com.example.missing")
        store.clear(for: "com.example.alpha")
        store.clearAll()
        store.recordPluginMessage(pluginID: "com.example.alpha", level: .debug)
        XCTAssertEqual(counts, [1, 0, 1])
        store.removeChangeObserver(observer)
        store.clearAll()
        XCTAssertTrue(store.allRecords().isEmpty)
        XCTAssertEqual(counts, [1, 0, 1])
    }

    func testActualRuntimePrimitiveExceptionDoesNotRetainSecretAndHealthySiblingStillRuns() async throws {
        let fixture = DiagnosticsRuntimeFixture()
        defer { fixture.shutdown() }
        let secret = "token=private-runtime-secret /Users/private/data.txt clipboard-private file-private"
        let failed = fixture.load(try package(id: "com.example.failed", source: "throw '\(secret)';"))
        let healthy = fixture.load(try package(id: "com.example.healthy", source: "function onStart() { globalThis.ready = true; }"))
        try await waitUntil { failed.snapshot.lastFailure != nil && healthy.snapshot.state == .running && !fixture.store.records(for: "com.example.failed").isEmpty }
        XCTAssertEqual(failed.snapshot.lastFailure?.phase, .entry)
        XCTAssertEqual(failed.snapshot.lastFailure?.code, .javaScriptException)
        XCTAssertEqual(failed.snapshot.lastFailure?.message, "JavaScript exception.")
        let result = try await healthy.evaluateForTesting("ready && 1 + 1 === 2")
        XCTAssertEqual(result, .boolean(true))
        XCTAssertTrue(fixture.lifecycle.allowsExecution(id: "com.example.healthy"))
        XCTAssertFalse(fixture.lifecycle.allowsExecution(id: "com.example.failed"))
        for fragment in ["private-runtime-secret", "/Users/private", "clipboard-private", "file-private"] {
            XCTAssertFalse(String(reflecting: failed.snapshot).contains(fragment))
            XCTAssertFalse(String(reflecting: fixture.store.allRecords()).contains(fragment))
            XCTAssertFalse(String(reflecting: fixture.bridge.logs(for: "com.example.failed")).contains(fragment))
        }
    }

    func testActualJavaScriptLogAcknowledgesPromiseWithoutRetainingUserContent() async throws {
        let fixture = DiagnosticsRuntimeFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(id: "com.example.logging", source: """
            function onStart() {
                island.log('token=private-log-secret /Users/private/path clipboard-private file-private', 'error')
                    .then(() => { globalThis.done = true; });
            }
            """))
        try await waitUntil { runtime.snapshot.state == .running && fixture.store.records(for: "com.example.logging").count == 1 }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while try await runtime.evaluateForTesting("globalThis.done === true") != .boolean(true) {
            guard ContinuousClock.now < deadline else { XCTFail("Log acknowledgement did not settle."); throw DiagnosticsTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        let entry = try XCTUnwrap(fixture.store.records(for: "com.example.logging").first)
        XCTAssertEqual(entry.category, .pluginMessage)
        XCTAssertEqual(entry.level, .error)
        XCTAssertEqual(entry.message, "Plugin log message omitted.")
        XCTAssertNil(runtime.snapshot.lastFailure)
        XCTAssertNil(fixture.lifecycle.snapshot(id: "com.example.logging")?.quarantine)
        for fragment in ["private-log-secret", "/Users/private", "clipboard-private", "file-private"] {
            XCTAssertFalse(String(reflecting: fixture.store.allRecords()).contains(fragment))
            XCTAssertFalse(String(reflecting: fixture.bridge.logs(for: "com.example.logging")).contains(fragment))
        }
    }

    private func package(id: String, source: String) throws -> ValidatedPluginPackage {
        let manifest = try PluginManifest(id: id, name: "Diagnostics Test", version: SemanticVersion("1.0.0"),
            engine: .javaScriptCore, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"), permissions: [], capabilities: [])
        let bytes = Data(source.utf8)
        return .init(manifest: manifest, canonicalRootURL: URL(fileURLWithPath: "/diagnostics-tests/\(id)", isDirectory: true),
                     entryRelativePath: "index.js", entrySource: bytes, regularFileCount: 2, totalFileBytes: UInt64(bytes.count))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Diagnostics fixture timed out."); throw DiagnosticsTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class DiagnosticsTestClock { var date = Date(timeIntervalSinceReferenceDate: 0) }

@MainActor
private final class DiagnosticsRuntimeFixture {
    let store = PluginDiagnosticsStore()
    let bridge: PluginJSBridge
    let lifecycle: PluginLifecycleBridge
    private let factory = DiagnosticsRuntimeFactory()

    init() {
        let bridge = PluginJSBridge(diagnostics: store)
        self.bridge = bridge
        let manager = ActivityManager(clock: TestActivityClock(Date(timeIntervalSinceReferenceDate: 1_000)), configuration: .immediate)
        let factory = factory
        lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: ActionRouter(manager: manager), diagnostics: store, runtimeFactory: { package in
            let runtime = PluginRuntime(package: package, bridge: bridge, diagnostics: bridge.diagnostics)
            factory.runtimes.append(runtime)
            return runtime
        })
    }

    func load(_ package: ValidatedPluginPackage) -> PluginRuntime {
        lifecycle.pluginDidLoad(package, isEnabled: true)
        return factory.runtimes.last!
    }
    func shutdown() { lifecycle.shutdown() }
}

@MainActor
private final class DiagnosticsRuntimeFactory { var runtimes: [PluginRuntime] = [] }
private nonisolated enum DiagnosticsTestError: Error { case timedOut }
