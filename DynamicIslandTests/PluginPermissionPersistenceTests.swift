import Darwin
import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginPermissionPersistenceTests: XCTestCase {
    private let id = "com.example.permission-persistence"

    func testFreshManagerRestoresExactPackageDecisionsAcrossDiskRestartAndDeclarationReordering() async throws {
        let workspace = try PermissionPersistenceWorkspace()
        defer { workspace.remove() }
        let package = try package(permissions: [.network, .localStorage], capabilities: [.publishActivity, .localStorage])
        let first = PermissionManager(decisionStore: workspace.store())
        await first.prepare(package: package)
        let review = try first.snapshot(package: package).review
        try await first.applyPersistentHostDecision(decision: .granted, review: review, permission: .localStorage)
        try await first.applyPersistentHostDecision(decision: .denied, review: review, permission: .network)

        let reordered = try self.package(permissions: [.localStorage, .network], capabilities: [.localStorage, .publishActivity])
        XCTAssertEqual(try PermissionManager.persistenceFingerprint(package: package),
                       try PermissionManager.persistenceFingerprint(package: reordered))
        let restored = PermissionManager(decisionStore: workspace.store())
        await restored.prepare(package: reordered)
        XCTAssertEqual(try restored.snapshot(package: reordered).states, [.localStorage: .granted, .network: .denied])
        XCTAssertNil(restored.persistenceError)
        XCTAssertNotEqual(try restored.snapshot(package: reordered).review.scope, review.scope)
        let lease = try restored.require(permission: .localStorage, package: reordered)
        XCTAssertEqual(try lease.perform { 42 }, 42)
        assertFailure(.denied) { try restored.require(permission: .network, package: reordered) }
    }

    func testCodeVersionDeveloperRuntimeProfileAndDeclarationsInvalidateSavedApproval() async throws {
        let changes = [
            try package(source: "function onStart() { globalThis.changed = true; }"),
            try package(version: "1.0.1"),
            try package(developer: "Different Developer"),
            try package(engine: .superIsland),
            try package(permissions: [.localStorage, .network]),
            try package(capabilities: [.localStorage, .publishActivity])
        ]
        for replacement in changes {
            let store = PluginPermissionDecisionStore()
            let original = try package()
            let first = PermissionManager(decisionStore: store)
            await first.prepare(package: original)
            try await first.applyPersistentHostDecision(decision: .granted,
                review: first.snapshot(package: original).review, permission: .localStorage)
            let fresh = PermissionManager(decisionStore: store)
            await fresh.prepare(package: replacement)
            let states = try fresh.snapshot(package: replacement).states
            XCTAssertTrue(states.values.allSatisfy { $0 == .requested })
            assertFailure(.notGranted) { try fresh.require(permission: .localStorage, package: replacement) }
            let saved = try await store.load()
            XCTAssertEqual(saved[id]?.fingerprint, try PermissionManager.persistenceFingerprint(package: replacement))
            XCTAssertEqual(saved[id]?.states, states)
        }
    }

    func testRuntimeProfileChangeRevokesLiveLeaseAndNeverReusesEarlierApproval() async throws {
        let store = PluginPermissionDecisionStore()
        let manager = PermissionManager(decisionStore: store)
        let native = try package()
        let compatible = try package(engine: .superIsland)
        XCTAssertNotEqual(try PermissionManager.persistenceFingerprint(package: native),
                          try PermissionManager.persistenceFingerprint(package: compatible))
        await manager.prepare(package: native)
        let oldReview = try manager.snapshot(package: native).review
        try await manager.applyPersistentHostDecision(decision: .granted, review: oldReview, permission: .localStorage)
        let oldLease = try manager.require(permission: .localStorage, package: native)

        await manager.prepare(package: compatible)
        XCTAssertEqual(try manager.state(permission: .localStorage, package: compatible), .requested)
        assertFailure(.revoked) { try oldLease.perform { XCTFail("Old runtime profile lease executed.") } }
        await assertAsyncFailure(.staleReview) {
            try await manager.applyPersistentHostDecision(decision: .granted, review: oldReview, permission: .localStorage)
        }
        await manager.prepare(package: native)
        XCTAssertEqual(try manager.state(permission: .localStorage, package: native), .requested)
        await assertAsyncFailure(.staleReview) {
            try await manager.applyPersistentHostDecision(decision: .granted, review: oldReview, permission: .localStorage)
        }
    }

    func testSameProcessReturningToPreviousCodeNeverRestoresOldApprovalOrReview() async throws {
        let store = PluginPermissionDecisionStore()
        let manager = PermissionManager(decisionStore: store)
        let original = try package()
        await manager.prepare(package: original)
        let oldReview = try manager.snapshot(package: original).review
        try await manager.applyPersistentHostDecision(decision: .granted, review: oldReview, permission: .localStorage)
        let oldLease = try manager.require(permission: .localStorage, package: original)
        let replacement = try package(source: "function onStart() { globalThis.replacement = true; }")
        await manager.prepare(package: replacement)
        assertFailure(.revoked) { try oldLease.perform { XCTFail("Old package lease executed.") } }
        await manager.prepare(package: original)
        XCTAssertEqual(try manager.state(permission: .localStorage, package: original), .requested)
        await assertAsyncFailure(.staleReview) {
            try await manager.applyPersistentHostDecision(decision: .granted, review: oldReview, permission: .localStorage)
        }
        let saved = try await store.load()
        XCTAssertEqual(saved[id]?.states[.localStorage], .requested)
    }

    func testSavedPermissionSetMismatchCannotRestoreEvenWithMatchingFingerprint() async throws {
        let store = PluginPermissionDecisionStore()
        let package = try package()
        let fingerprint = try PermissionManager.persistenceFingerprint(package: package)
        try await store.replace(record: .init(pluginID: id, fingerprint: fingerprint,
                                             states: [.localStorage: .requested, .network: .requested]))
        try await store.setDecision(pluginID: id, fingerprint: fingerprint, permission: .localStorage, state: .granted)
        let manager = PermissionManager(decisionStore: store)
        await manager.prepare(package: package)
        XCTAssertEqual(try manager.snapshot(package: package).states, [.localStorage: .requested])
        let saved = try await store.load()
        XCTAssertEqual(saved[id]?.states, [.localStorage: .requested])
    }

    func testAdministrativeRevocationSupersedesPendingGrantAndCompensatesDurableState() async throws {
        let workspace = try PermissionPersistenceWorkspace()
        defer { workspace.remove() }
        let replacer = PermissionPersistenceControlledReplacer()
        defer { replacer.release() }
        let store = workspace.store(replacer: replacer)
        let manager = PermissionManager(decisionStore: store)
        let package = try package()
        await manager.prepare(package: package)
        let review = try manager.snapshot(package: package).review
        replacer.holdNextReplacement()
        let grant = Task { try await manager.applyPersistentHostDecision(decision: .granted, review: review, permission: .localStorage) }
        try await waitForIO(replacer)
        XCTAssertEqual(try manager.state(permission: .localStorage, package: package), .requested)
        XCTAssertFalse(replacer.wasOnMainThread)
        try manager.applyHostDecision(decision: .revoked, review: review, permission: .localStorage)
        replacer.release()
        await assertAsyncFailure(.staleReview) { try await grant.value }
        XCTAssertEqual(try manager.state(permission: .localStorage, package: package), .revoked)
        let saved = try await store.load()
        XCTAssertEqual(saved[id]?.states[.localStorage], .revoked)
        let fresh = PermissionManager(decisionStore: workspace.store())
        await fresh.prepare(package: package)
        XCTAssertEqual(try fresh.state(permission: .localStorage, package: package), .revoked)
        assertFailure(.revoked) { try fresh.require(permission: .localStorage, package: package) }
    }

    func testAdministrativeRevokeWhileRestorationLoadIsQueuedNeverReopensGate() async throws {
        let workspace = try PermissionPersistenceWorkspace()
        defer { workspace.remove() }
        let replacer = PermissionPersistenceControlledReplacer()
        defer { replacer.release() }
        let store = workspace.store(replacer: replacer)
        let package = try package()
        let original = PermissionManager(decisionStore: store)
        await original.prepare(package: package)
        try await original.applyPersistentHostDecision(decision: .granted,
            review: original.snapshot(package: package).review, permission: .localStorage)
        let fingerprint = try PermissionManager.persistenceFingerprint(package: package)
        replacer.holdNextReplacement()
        let heldWrite = Task {
            try await store.setDecision(pluginID: id, fingerprint: fingerprint, permission: .localStorage, state: .granted)
        }
        try await waitForIO(replacer)
        let manager = PermissionManager(decisionStore: store)
        var registered = false
        let observer = manager.observeChanges { registered = true }
        let preparation = Task { await manager.prepare(package: package) }
        try await waitUntil { registered }
        let review = try manager.snapshot(package: package).review
        try manager.applyHostDecision(decision: .revoked, review: review, permission: .localStorage)
        assertFailure(.revoked) { try manager.require(permission: .localStorage, package: package) }
        replacer.release()
        try await heldWrite.value
        await preparation.value
        manager.removeChangeObserver(observer)
        XCTAssertEqual(try manager.state(permission: .localStorage, package: package), .revoked)
        assertFailure(.revoked) { try manager.require(permission: .localStorage, package: package) }
    }

    func testPersistentRevokeQueuedDuringRestorationClosesGateImmediatelyAndSurvivesRestart() async throws {
        let workspace = try PermissionPersistenceWorkspace()
        defer { workspace.remove() }
        let replacer = PermissionPersistenceControlledReplacer()
        defer { replacer.release() }
        let store = workspace.store(replacer: replacer)
        let package = try package()
        let original = PermissionManager(decisionStore: store)
        await original.prepare(package: package)
        try await original.applyPersistentHostDecision(decision: .granted,
            review: original.snapshot(package: package).review, permission: .localStorage)
        let fingerprint = try PermissionManager.persistenceFingerprint(package: package)
        replacer.holdNextReplacement()
        let heldWrite = Task {
            try await store.setDecision(pluginID: id, fingerprint: fingerprint, permission: .localStorage, state: .granted)
        }
        try await waitForIO(replacer)
        let manager = PermissionManager(decisionStore: store)
        var registered = false
        let observer = manager.observeChanges { registered = true }
        let preparation = Task { await manager.prepare(package: package) }
        try await waitUntil { registered }
        let review = try manager.snapshot(package: package).review
        let revocation = Task {
            try await manager.applyPersistentHostDecision(decision: .revoked, review: review, permission: .localStorage)
        }
        try await waitUntil { (try? manager.state(permission: .localStorage, package: package)) == .revoked }
        assertFailure(.revoked) { try manager.require(permission: .localStorage, package: package) }
        replacer.release()
        try await heldWrite.value
        await preparation.value
        try await revocation.value
        manager.removeChangeObserver(observer)
        XCTAssertEqual(try manager.state(permission: .localStorage, package: package), .revoked)
        let saved = try await store.load()
        XCTAssertEqual(saved[id]?.states[.localStorage], .revoked)
        let restarted = PermissionManager(decisionStore: workspace.store())
        await restarted.prepare(package: package)
        assertFailure(.revoked) { try restarted.require(permission: .localStorage, package: package) }
    }

    func testRepeatedPreparationDoesNotReplaySavedGrantAfterAdministrativeRevoke() async throws {
        let manager = PermissionManager(decisionStore: PluginPermissionDecisionStore())
        let package = try package()
        await manager.prepare(package: package)
        try await manager.applyPersistentHostDecision(decision: .granted,
            review: manager.snapshot(package: package).review, permission: .localStorage)
        let lease = try manager.require(permission: .localStorage, package: package)
        manager.revokeAll()
        await manager.prepare(package: package)
        XCTAssertEqual(try manager.state(permission: .localStorage, package: package), .revoked)
        assertFailure(.revoked) { try lease.perform { XCTFail("Prepare replayed an old grant.") } }
    }

    func testApprovalWriteFailureLeavesPermissionRequestedAndSavedBytesUntouched() async throws {
        let workspace = try PermissionPersistenceWorkspace()
        defer { workspace.remove() }
        let replacer = PermissionPersistenceControlledReplacer()
        let store = workspace.store(replacer: replacer)
        let manager = PermissionManager(decisionStore: store)
        let package = try package()
        await manager.prepare(package: package)
        let before = try Data(contentsOf: workspace.file)
        replacer.failReplacements(true)
        await assertAsyncFailure(.persistenceFailed) {
            try await manager.applyPersistentHostDecision(decision: .granted,
                review: manager.snapshot(package: package).review, permission: .localStorage)
        }
        XCTAssertEqual(try manager.state(permission: .localStorage, package: package), .requested)
        assertFailure(.notGranted) { try manager.require(permission: .localStorage, package: package) }
        XCTAssertEqual(try Data(contentsOf: workspace.file), before)
        XCTAssertEqual(manager.persistenceError, "授权记录保存失败，批准未生效。")
    }

    func testRevocationClosesOldLeaseBeforeFailedDurableReplacementCompletes() async throws {
        let workspace = try PermissionPersistenceWorkspace()
        defer { workspace.remove() }
        let replacer = PermissionPersistenceControlledReplacer()
        defer { replacer.release() }
        let manager = PermissionManager(decisionStore: workspace.store(replacer: replacer))
        let package = try package()
        await manager.prepare(package: package)
        let review = try manager.snapshot(package: package).review
        try await manager.applyPersistentHostDecision(decision: .granted, review: review, permission: .localStorage)
        let lease = try manager.require(permission: .localStorage, package: package)
        let before = try Data(contentsOf: workspace.file)
        replacer.holdNextReplacement()
        replacer.failReplacements(true)
        let revocation = Task { try await manager.applyPersistentHostDecision(decision: .revoked, review: review, permission: .localStorage) }
        try await waitForIO(replacer)
        XCTAssertEqual(try manager.state(permission: .localStorage, package: package), .revoked)
        assertFailure(.revoked) { try lease.perform { XCTFail("Lease survived synchronous revoke.") } }
        replacer.release()
        await assertAsyncFailure(.persistenceFailed) { try await revocation.value }
        XCTAssertEqual(try Data(contentsOf: workspace.file), before)
        XCTAssertEqual(manager.persistenceError, "本次授权已撤销，授权记录保存失败。")
        assertFailure(.revoked) { try manager.require(permission: .localStorage, package: package) }
    }

    func testRemovingSavedDecisionInvalidatesLeasesAndFreshManagerCannotRestoreIt() async throws {
        let workspace = try PermissionPersistenceWorkspace()
        defer { workspace.remove() }
        let store = workspace.store()
        let manager = PermissionManager(decisionStore: store)
        let package = try package()
        await manager.prepare(package: package)
        try await manager.applyPersistentHostDecision(decision: .granted,
            review: manager.snapshot(package: package).review, permission: .localStorage)
        let lease = try manager.require(permission: .localStorage, package: package)
        try await manager.forgetPersisted(pluginID: id)
        assertFailure(.revoked) { try lease.perform { XCTFail("Removed approval retained its lease.") } }
        let empty = try await store.load()
        XCTAssertNil(empty[id])
        let fresh = PermissionManager(decisionStore: workspace.store())
        await fresh.prepare(package: package)
        XCTAssertEqual(try fresh.state(permission: .localStorage, package: package), .requested)
    }

    func testFailedRemovalSuppressesApprovalRestorationWithinCurrentProcessAndReportsFailure() async throws {
        let workspace = try PermissionPersistenceWorkspace()
        defer { workspace.remove() }
        let replacer = PermissionPersistenceControlledReplacer()
        let store = workspace.store(replacer: replacer)
        let manager = PermissionManager(decisionStore: store)
        let package = try package()
        await manager.prepare(package: package)
        try await manager.applyPersistentHostDecision(decision: .granted,
            review: manager.snapshot(package: package).review, permission: .localStorage)
        let lease = try manager.require(permission: .localStorage, package: package)
        replacer.failReplacements(true)
        await assertAsyncFailure(.persistenceFailed) { try await manager.forgetPersisted(pluginID: self.id) }
        XCTAssertEqual(manager.persistenceError, "本次授权已撤销，授权记录移除失败。")
        assertFailure(.revoked) { try lease.perform { XCTFail("Failed removal retained active approval.") } }
        await manager.prepare(package: package)
        XCTAssertEqual(try manager.state(permission: .localStorage, package: package), .requested)
        assertFailure(.notGranted) { try manager.require(permission: .localStorage, package: package) }
        // The error remains visible; the saved grant has not been removed.
        let remaining = try await store.load()
        XCTAssertEqual(remaining[id]?.states[.localStorage], .granted)
        XCTAssertNotNil(manager.persistenceError)
        replacer.failReplacements(false)
        await manager.prepare(package: package)
        let repairedByExplicitRegistration = try await store.load()
        XCTAssertEqual(repairedByExplicitRegistration[id]?.states[.localStorage], .requested)
    }

    func testCorruptOrUnreadableApprovalFileNeverRestoresGrantOrAllowsNewApproval() async throws {
        for kind in ["corrupt", "mode"] {
            let workspace = try PermissionPersistenceWorkspace()
            defer { workspace.remove() }
            let store = workspace.store()
            let package = try package()
            let first = PermissionManager(decisionStore: store)
            await first.prepare(package: package)
            try await first.applyPersistentHostDecision(decision: .granted,
                review: first.snapshot(package: package).review, permission: .localStorage)
            if kind == "corrupt" { try Data("{\"schemaVersion\":2,\"records\":{}}".utf8).write(to: workspace.file) }
            else { XCTAssertEqual(chmod(workspace.file.path, 0o666), 0) }
            let before = try Data(contentsOf: workspace.file)
            let fresh = PermissionManager(decisionStore: workspace.store())
            await fresh.prepare(package: package)
            XCTAssertEqual(try fresh.state(permission: .localStorage, package: package), .requested)
            XCTAssertEqual(fresh.persistenceError, "授权记录无法读取或保存。未保存的批准不会生效。")
            await assertAsyncFailure(.persistenceFailed) {
                try await fresh.applyPersistentHostDecision(decision: .granted,
                    review: fresh.snapshot(package: package).review, permission: .localStorage)
            }
            XCTAssertEqual(try Data(contentsOf: workspace.file), before)
        }
    }

    func testChangesNotifyHostAndRemovedObserverReceivesNoFurtherUpdates() async throws {
        let manager = PermissionManager(decisionStore: PluginPermissionDecisionStore())
        let package = try package()
        var count = 0
        let token = manager.observeChanges { count += 1 }
        await manager.prepare(package: package)
        XCTAssertGreaterThanOrEqual(count, 2)
        let before = count
        try await manager.applyPersistentHostDecision(decision: .granted,
            review: manager.snapshot(package: package).review, permission: .localStorage)
        XCTAssertGreaterThan(count, before)
        manager.removeChangeObserver(token)
        let removed = count
        try await manager.applyPersistentHostDecision(decision: .revoked,
            review: manager.snapshot(package: package).review, permission: .localStorage)
        XCTAssertEqual(count, removed)
    }

    func testManagerPreparesRestoredGrantBeforeRealJavaScriptOnStartReadsStorage() async throws {
        let workspace = try PermissionPersistenceWorkspace()
        defer { workspace.remove() }
        let configuration = PluginManagerConfiguration(rootDirectoryURL: workspace.configuration.rootDirectoryURL,
                                                       hostVersion: try SemanticVersion("0.6.0"))
        let initialManager = PluginManager(configuration: configuration)
        let initialReport = await initialManager.discover()
        XCTAssertTrue(initialReport.failures.isEmpty)
        let root = configuration.installedDirectoryURL.appendingPathComponent("PersistencePlugin", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let source = """
            function onStart() {
                island.storage.get('seed').then(value => {
                    globalThis.restored = value === 'stored-before-restart';
                    globalThis.failureCode = null; globalThis.done = true;
                }).catch(error => { globalThis.failureCode = error.code; globalThis.done = true; });
            }
            """
        let package = try self.package(source: source, root: root)
        try package.manifest.encodeJSON().write(to: root.appendingPathComponent("manifest.json"))
        try package.entrySource.write(to: root.appendingPathComponent("index.js"))
        let discovery = await initialManager.discover()
        XCTAssertTrue(discovery.failures.isEmpty)
        _ = try await initialManager.enable(id: id)

        let firstPermissions = PermissionManager(decisionStore: workspace.store())
        await firstPermissions.prepare(package: package)
        try await firstPermissions.applyPersistentHostDecision(decision: .granted,
            review: firstPermissions.snapshot(package: package).review, permission: .localStorage)
        let storage = PluginStorage(configuration: .init(rootDirectoryURL: configuration.rootDirectoryURL))
        try await storage.set(pluginID: id, key: "seed", value: .string("stored-before-restart"))

        let permissions = PermissionManager(decisionStore: workspace.store())
        let bridge = PluginJSBridge(storage: storage, permissions: permissions)
        let activities = ActivityManager(clock: TestActivityClock(Date(timeIntervalSinceReferenceDate: 104_000)), configuration: .immediate)
        let collector = PermissionPersistenceRuntimeCollector()
        let lifecycle = PluginLifecycleBridge(activityManager: activities, actionRouter: ActionRouter(manager: activities),
            permissions: permissions, runtimeFactory: { package in
                let runtime = PluginRuntime(package: package, bridge: bridge)
                collector.runtime = runtime
                return PermissionPersistenceRuntimeForwarder(runtime: runtime, package: package,
                                                             permissions: permissions, collector: collector)
            })
        defer { lifecycle.shutdown() }
        let restarted = PluginManager(configuration: configuration, lifecycleHandler: lifecycle)
        let report = await restarted.discover()
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.plugins.first?.isEnabled, true)
        XCTAssertEqual(collector.permissionAtStart, .granted)
        let runtime = try XCTUnwrap(collector.runtime)
        try await marker(runtime)
        let restoredValue = try await runtime.evaluateForTesting("globalThis.restored")
        let failureCode = try await runtime.evaluateForTesting("globalThis.failureCode")
        XCTAssertEqual(restoredValue, .boolean(true))
        XCTAssertEqual(failureCode, .null)
        XCTAssertEqual(lifecycle.snapshot(id: id)?.state, .running)
    }

    private func package(source: String = "function onStart() {}", version: String = "1.0.0",
                         developer: String? = "Original Developer", engine: PluginEngine = .javaScriptCore,
                         permissions: [PluginPermission] = [.localStorage],
                         capabilities: [PluginCapability] = [.localStorage], root: URL? = nil) throws -> ValidatedPluginPackage {
        let manifest = try PluginManifest(id: id, name: "Permission Persistence", version: SemanticVersion(version),
            engine: engine, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"),
            permissions: permissions, capabilities: capabilities, developer: developer)
        let bytes = Data(source.utf8)
        return .init(manifest: manifest, canonicalRootURL: root ?? URL(fileURLWithPath: "/permission-persistence-tests/\(id)", isDirectory: true),
                     entryRelativePath: "index.js", entrySource: bytes, regularFileCount: 2, totalFileBytes: UInt64(bytes.count))
    }

    private func assertFailure<T>(_ expected: PluginPermissionError, file: StaticString = #filePath, line: UInt = #line,
                                  _ body: () throws -> T) {
        do { _ = try body(); XCTFail("Expected fixed permission error.", file: file, line: line) }
        catch { XCTAssertEqual(error as? PluginPermissionError, expected, file: file, line: line) }
    }

    private func assertAsyncFailure<T>(_ expected: PluginPermissionError, file: StaticString = #filePath, line: UInt = #line,
                                       _ body: () async throws -> T) async {
        do { _ = try await body(); XCTFail("Expected fixed permission error.", file: file, line: line) }
        catch { XCTAssertEqual(error as? PluginPermissionError, expected, file: file, line: line) }
    }

    private func waitForIO(_ replacer: PermissionPersistenceControlledReplacer) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !replacer.hasEntered {
            guard ContinuousClock.now < deadline else { replacer.release(); throw PermissionPersistenceTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw PermissionPersistenceTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func marker(_ runtime: PluginRuntime) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while runtime.snapshot.state != .running {
            guard runtime.snapshot.lastFailure == nil, ContinuousClock.now < deadline else { throw PermissionPersistenceTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        while try await runtime.evaluateForTesting("globalThis.done === true") != .boolean(true) {
            guard ContinuousClock.now < deadline else { throw PermissionPersistenceTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum PermissionPersistenceTestError: Error { case timedOut }

private struct PermissionPersistenceWorkspace {
    let configuration: PluginPermissionDecisionStoreConfiguration
    var file: URL { configuration.fileURL }

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("permission-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        configuration = .init(rootDirectoryURL: root)
    }
    func store() -> PluginPermissionDecisionStore { .init(configuration: configuration) }
    func store(replacer: any PluginPermissionDecisionFileReplacing) -> PluginPermissionDecisionStore {
        .init(configuration: configuration, replacer: replacer)
    }
    func remove() { try? FileManager.default.removeItem(at: configuration.rootDirectoryURL) }
}

private nonisolated final class PermissionPersistenceControlledReplacer: PluginPermissionDecisionFileReplacing, @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var hold = false
    private var shouldFail = false
    private var entered = false
    private var mainThread = false

    var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    var wasOnMainThread: Bool { lock.lock(); defer { lock.unlock() }; return mainThread }
    func holdNextReplacement() { lock.lock(); hold = true; entered = false; lock.unlock() }
    func failReplacements(_ value: Bool) { lock.lock(); shouldFail = value; lock.unlock() }
    func release() { semaphore.signal() }

    func replace(preparedFile: URL, destination: URL, directoryDescriptor: Int32) throws {
        lock.lock()
        let mustHold = hold
        hold = false
        if mustHold { entered = true; mainThread = Thread.isMainThread }
        lock.unlock()
        if mustHold, semaphore.wait(timeout: .now() + 5) == .timedOut { throw PluginPermissionDecisionStoreError.writeFailed }
        lock.lock(); let fail = shouldFail; lock.unlock()
        guard !fail, renameat(directoryDescriptor, preparedFile.lastPathComponent,
                             directoryDescriptor, destination.lastPathComponent) == 0 else {
            throw PluginPermissionDecisionStoreError.writeFailed
        }
    }
}

@MainActor
private final class PermissionPersistenceRuntimeCollector {
    var runtime: PluginRuntime?
    var permissionAtStart: PluginPermissionState?
}

@MainActor
private final class PermissionPersistenceRuntimeForwarder: PluginLifecycleRuntime {
    let runtime: PluginRuntime
    let package: ValidatedPluginPackage
    let permissions: PermissionManager
    let collector: PermissionPersistenceRuntimeCollector
    init(runtime: PluginRuntime, package: ValidatedPluginPackage, permissions: PermissionManager,
         collector: PermissionPersistenceRuntimeCollector) {
        self.runtime = runtime; self.package = package; self.permissions = permissions; self.collector = collector
    }
    func onStart(context: PluginExecutionContext) throws {
        collector.permissionAtStart = try permissions.state(permission: .localStorage, package: package)
        try runtime.onStart(context: context)
    }
    func onStop(reason: PluginStopReason) throws { try runtime.onStop(reason: reason) }
    func teardown() { runtime.teardown() }
}
