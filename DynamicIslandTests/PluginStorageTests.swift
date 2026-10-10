import Darwin
import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginStorageTests: XCTestCase {
    private let alpha = "com.example.storage.alpha"
    private let beta = "com.example.storage.beta"

    func testMemoryNamespacesKeepSameKeyAndCleanupIndependent() async throws {
        let store = PluginStorage()
        let document = PluginBridgeJSON.object(["enabled": .boolean(true), "rows": .array([.null, .number(3), .string("测试")])])
        try await store.set(pluginID: alpha, key: "same", value: document)
        try await store.set(pluginID: alpha, key: "../outside", value: .string("JSON key"))
        try await store.set(pluginID: beta, key: "same", value: .string("beta"))
        try await assertValue(store, pluginID: alpha, key: "same", equals: document)
        try await assertValue(store, pluginID: beta, key: "same", equals: .string("beta"))
        try await store.remove(pluginID: alpha, key: "same")
        try await assertValue(store, pluginID: alpha, key: "same", equals: .null)
        try await store.clear(pluginID: alpha)
        try await assertValue(store, pluginID: beta, key: "same", equals: .string("beta"))
    }

    func testDiskRoundTripSurvivesNewStoreAndUsesPrivateModes() async throws {
        let workspace = try StorageWorkspace()
        defer { workspace.remove() }
        let store = PluginStorage(configuration: workspace.configuration)
        try FileManager.default.removeItem(at: workspace.configuration.rootDirectoryURL)
        let document = PluginBridgeJSON.object(["nullable": .null, "unicode": .string("你好 👋"), "nested": .array([.boolean(false), .number(-1.25)])])
        try await store.set(pluginID: alpha, key: "settings", value: document)
        try await store.set(pluginID: alpha, key: "../outside", value: .string("JSON key"))
        try await store.set(pluginID: alpha, key: "toJSON", value: .boolean(true))
        try await store.set(pluginID: beta, key: "settings", value: .number(7))
        let restored = PluginStorage(configuration: workspace.configuration)
        try await assertValue(restored, pluginID: alpha, key: "settings", equals: document)
        try await assertValue(restored, pluginID: alpha, key: "../outside", equals: .string("JSON key"))
        try await assertValue(restored, pluginID: alpha, key: "toJSON", equals: .boolean(true))
        try await assertValue(restored, pluginID: beta, key: "settings", equals: .number(7))
        XCTAssertEqual(try permissions(workspace.configuration.rootDirectoryURL), 0o700)
        XCTAssertEqual(try permissions(workspace.configuration.directoryURL), 0o700)
        XCTAssertEqual(try permissions(workspace.file(alpha)), 0o600)
        var status = stat()
        XCTAssertEqual(lstat(try workspace.file(alpha).path, &status), 0)
        XCTAssertEqual(status.st_nlink, 1)
        XCTAssertEqual(status.st_uid, geteuid())
    }

    func testRealJavaScriptPersistsAcrossNewStoreBridgeAndRuntime() async throws {
        let workspace = try StorageWorkspace()
        defer { workspace.remove() }
        let first = StorageRuntimeFixture(store: PluginStorage(configuration: workspace.configuration))
        let write = """
            function onStart() {
                island.storage.set('same', {owner:island.plugin.id, rows:['测试', null, true]})
                    .then(() => { globalThis.done = true; });
            }
            """
        let firstAlpha = first.load(try package(id: alpha, source: write))
        let firstBeta = first.load(try package(id: beta, source: write))
        try await marker(firstAlpha, "done")
        try await marker(firstBeta, "done")
        first.shutdown()

        let second = StorageRuntimeFixture(store: PluginStorage(configuration: workspace.configuration))
        defer { second.shutdown() }
        let read = """
            function onStart() {
                island.storage.get('same').then(value => {
                    globalThis.restored = value.owner === island.plugin.id && value.rows[0] === '测试' &&
                        value.rows[1] === null && value.rows[2] === true;
                    globalThis.done = true;
                });
            }
            """
        let restoredAlpha = second.load(try package(id: alpha, source: read))
        let restoredBeta = second.load(try package(id: beta, source: read))
        try await marker(restoredAlpha, "done")
        try await marker(restoredBeta, "done")
        try await assertJavaScript(restoredAlpha, "restored", equals: .boolean(true))
        try await assertJavaScript(restoredBeta, "restored", equals: .boolean(true))
        _ = try await restoredAlpha.evaluateForTesting("island.storage.clear().then(() => {globalThis.cleared=true;}); void 0")
        try await marker(restoredAlpha, "cleared")
        let third = PluginStorage(configuration: workspace.configuration)
        try await assertValue(third, pluginID: alpha, key: "same", equals: .null)
        try await assertValue(third, pluginID: beta, key: "same", equals: .object(["owner": .string(beta), "rows": .array([.string("测试"), .null, .boolean(true)])]))
    }

    func testRealJavaScriptUnawaitedStorageCallsKeepFIFOThroughDiskIO() async throws {
        let workspace = try StorageWorkspace()
        defer { workspace.remove() }
        let fixture = StorageRuntimeFixture(store: PluginStorage(configuration: workspace.configuration))
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(id: alpha, source: """
            function onStart() {
                const requests = [island.storage.set('first', 1), island.storage.get('first'),
                    island.storage.set('second', 2), island.storage.remove('first'),
                    island.storage.get('first'), island.storage.clear(), island.storage.get('second')];
                Promise.all(requests).then(values => {
                    globalThis.ordered = values[1] === 1 && values[4] === null && values[6] === null;
                    globalThis.done = true;
                });
            }
            """))
        try await marker(runtime, "done")
        try await assertJavaScript(runtime, "ordered", equals: .boolean(true))
        let restored = PluginStorage(configuration: workspace.configuration)
        try await assertValue(restored, pluginID: alpha, key: "first", equals: .null)
        try await assertValue(restored, pluginID: alpha, key: "second", equals: .null)
    }

    func testUTF8KeyAndStringLimitsRejectWithoutChangingDisk() async throws {
        let workspace = try StorageWorkspace()
        defer { workspace.remove() }
        let store = PluginStorage(configuration: workspace.configuration)
        let key = String(repeating: "界", count: 42) + "ab"
        let value = String(repeating: "界", count: 1_365) + "a"
        XCTAssertEqual(key.utf8.count, 128)
        XCTAssertEqual(value.utf8.count, 4_096)
        try await store.set(pluginID: alpha, key: key, value: .string(value))
        let before = try Data(contentsOf: workspace.file(alpha))
        await assertFailure(.quotaExceeded) { try await store.set(pluginID: self.alpha, key: key + "a", value: .number(2)) }
        await assertFailure(.quotaExceeded) { try await store.set(pluginID: self.alpha, key: key, value: .string(value + "a")) }
        for invalid in ["", " \n ", "nul\u{0000}key", "line\nkey"] {
            await assertFailure(.invalidArguments) { try await store.set(pluginID: self.alpha, key: invalid, value: .number(2)) }
        }
        XCTAssertEqual(try Data(contentsOf: workspace.file(alpha)), before)
        try await assertValue(store, pluginID: alpha, key: key, equals: .string(value))
    }

    func testNamespaceQuotasPermitOverwriteAndCleanupWithoutPartialCommit() async throws {
        let memory = PluginStorage()
        for index in 0..<128 { try await memory.set(pluginID: alpha, key: "k\(index)", value: .number(Double(index))) }
        await assertFailure(.quotaExceeded) { try await memory.set(pluginID: self.alpha, key: "overflow", value: .boolean(true)) }
        try await memory.set(pluginID: alpha, key: "k0", value: .number(42))
        try await memory.remove(pluginID: alpha, key: "k1")
        try await memory.set(pluginID: alpha, key: "replacement", value: .boolean(true))
        try await assertValue(memory, pluginID: alpha, key: "overflow", equals: .null)
        try await assertValue(memory, pluginID: alpha, key: "k0", equals: .number(42))

        let workspace = try StorageWorkspace()
        defer { workspace.remove() }
        let disk = PluginStorage(configuration: workspace.configuration)
        let bulk = PluginBridgeJSON.array([.string(String(repeating: "x", count: 4_000)), .string(String(repeating: "y", count: 4_000))])
        for index in 0..<8 { try await disk.set(pluginID: alpha, key: "bulk\(index)", value: bulk) }
        let before = try Data(contentsOf: workspace.file(alpha))
        await assertFailure(.quotaExceeded) { try await disk.set(pluginID: self.alpha, key: "overflow", value: .string(String(repeating: "z", count: 2_000))) }
        XCTAssertEqual(try Data(contentsOf: workspace.file(alpha)), before)
        let restored = PluginStorage(configuration: workspace.configuration)
        try await assertValue(restored, pluginID: alpha, key: "overflow", equals: .null)
        try await assertValue(restored, pluginID: alpha, key: "bulk7", equals: bulk)
        try await disk.clear(pluginID: alpha)
        try await disk.set(pluginID: alpha, key: "fresh", value: .boolean(true))
    }

    func testActorRejectsInvalidPluginIdentityAndDataWithoutCreatingFiles() async throws {
        let workspace = try StorageWorkspace()
        defer { workspace.remove() }
        let store = PluginStorage(configuration: workspace.configuration)
        for id in ["../outside", "com.example/escape", "UPPER.example", "single"] {
            await assertFailure(.invalidArguments) { try await store.set(pluginID: id, key: "safe", value: .number(1)) }
        }
        for value in [PluginBridgeJSON.number(.infinity), .object(["toJSON": .number(1)])] {
            await assertFailure(.invalidArguments) { try await store.set(pluginID: self.alpha, key: "safe", value: value) }
        }
        var deep = PluginBridgeJSON.null
        for _ in 0..<8 { deep = .array([deep]) }
        let tooDeep = deep
        await assertFailure(.quotaExceeded) { try await store.set(pluginID: self.alpha, key: "safe", value: tooDeep) }
        await assertFailure(.quotaExceeded) { try await store.set(pluginID: self.alpha, key: "safe", value: .array(Array(repeating: .null, count: 256))) }
        await assertFailure(.quotaExceeded) { try await store.set(pluginID: self.alpha, key: "safe", value: .array([.string(String(repeating: "x", count: 4_096)), .string(String(repeating: "y", count: 4_096))])) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try workspace.file(alpha).path))
    }

    func testCorruptSchemaDuplicateFieldsAndWrongIdentityFailClosed() async throws {
        let files = [
            "{\"schemaVersion\":2,\"pluginID\":\"\(alpha)\",\"values\":{\"safe\":1}}",
            "{\"schemaVersion\":1,\"schemaVersion\":1,\"pluginID\":\"\(alpha)\",\"values\":{}}",
            "{\"schemaVersion\":1,\"pluginID\":\"\(alpha)\",\"values\":{\"safe\":1,\"safe\":2}}",
            "{\"schemaVersion\":1,\"pluginID\":\"\(alpha)\",\"values\":{\"safe\":{\"nested\":1,\"nested\":2}}}",
            "{\"schemaVersion\":1,\"pluginID\":\"\(beta)\",\"values\":{\"safe\":1}}",
            "{\"schemaVersion\":1,\"pluginID\":\"\(alpha)\",\"values\":{},\"unknown\":true}"
        ]
        for source in files { try await assertCorruptFile(Data(source.utf8)) }

        let workspace = try StorageWorkspace()
        defer { workspace.remove() }
        try workspace.seed(Data("{}".utf8), pluginID: alpha)
        let fixture = StorageRuntimeFixture(store: PluginStorage(configuration: workspace.configuration))
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(id: alpha, source: """
            function onStart() {
                island.storage.get('safe').catch(error => {
                    globalThis.code = error.code; globalThis.message = error.message; globalThis.done = true;
                });
            }
            """))
        try await marker(runtime, "done")
        try await assertJavaScript(runtime, "code", equals: .string("storageReadFailed"))
        try await assertJavaScript(runtime, "message", equals: .string("Plugin storage could not be read."))
    }

    func testInvalidStoredKeysValuesAndAggregateQuotasFailClosed() async throws {
        var invalid: [[String: Any]] = [
            ["": 1], ["line\nkey": 1], [String(repeating: "界", count: 43): 1],
            ["safe": ["toJSON": 1]], ["safe": String(repeating: "界", count: 1_366)],
            ["safe": Array(repeating: NSNull(), count: 256)]
        ]
        invalid.append(Dictionary(uniqueKeysWithValues: (0..<129).map { ("k\($0)", $0 as Any) }))
        invalid.append(Dictionary(uniqueKeysWithValues: (0..<17).map { ("k\($0)", String(repeating: "x", count: 4_000) as Any) }))
        for values in invalid {
            let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "pluginID": alpha, "values": values])
            try await assertCorruptFile(data)
        }
    }

    func testOversizedAndInvalidUTF8FilesAreRejectedBeforeRecoveryWrite() async throws {
        try await assertCorruptFile(Data(repeating: 32, count: 131_073))
        try await assertCorruptFile(Data([0xff, 0xfe, 0x00]))
    }

    func testSymlinkHardlinkAndInsecureFileModesNeverReadOrOverwriteTargets() async throws {
        for kind in ["symlink", "hardlink", "mode"] {
            let workspace = try StorageWorkspace()
            defer { workspace.remove() }
            let store = PluginStorage(configuration: workspace.configuration)
            try await store.set(pluginID: alpha, key: "safe", value: .number(1))
            let namespace = try workspace.file(alpha)
            let external = workspace.configuration.rootDirectoryURL.appendingPathComponent("external.json")
            let before = try Data(contentsOf: namespace)
            try before.write(to: external)
            XCTAssertEqual(chmod(external.path, 0o600), 0)
            if kind == "symlink" {
                try FileManager.default.removeItem(at: namespace)
                try FileManager.default.createSymbolicLink(at: namespace, withDestinationURL: external)
            } else if kind == "hardlink" {
                try FileManager.default.removeItem(at: namespace)
                XCTAssertEqual(link(external.path, namespace.path), 0)
            } else {
                XCTAssertEqual(chmod(namespace.path, 0o666), 0)
            }
            await assertFailure(.readFailed) { try await store.get(pluginID: self.alpha, key: "safe") }
            await assertFailure(.readFailed) { try await store.set(pluginID: self.alpha, key: "safe", value: .number(2)) }
            XCTAssertEqual(try Data(contentsOf: external), before, kind)
            XCTAssertEqual(try Data(contentsOf: namespace), before, kind)
        }
    }

    func testSymlinkAndInsecureManagedDirectoriesAreRejected() async throws {
        for kind in ["rootSymlink", "storageSymlink", "rootMode", "storageMode"] {
            let workspace = try StorageWorkspace()
            defer { workspace.remove() }
            let external = FileManager.default.temporaryDirectory.appendingPathComponent("PluginStorageExternal-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: external) }
            let target = kind.hasPrefix("root") ? workspace.configuration.rootDirectoryURL : workspace.configuration.directoryURL
            if kind.hasSuffix("Symlink") {
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: external)
            } else {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                XCTAssertEqual(chmod(target.path, 0o777), 0)
            }
            let store = PluginStorage(configuration: workspace.configuration)
            await assertFailure(.readFailed) { try await store.get(pluginID: self.alpha, key: "safe") }
            await assertFailure(.readFailed) { try await store.set(pluginID: self.alpha, key: "safe", value: .number(2)) }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty, kind)
        }
    }

    func testForeignOwnerManagedRootIsRejectedWithoutWriting() async throws {
        guard geteuid() != 0 else { throw XCTSkip("The ownership boundary requires a non-root test process.") }
        let foreignRoot = URL(fileURLWithPath: "/private/var/empty", isDirectory: true)
        var status = stat()
        guard lstat(foreignRoot.path, &status) == 0, status.st_uid != geteuid() else {
            throw XCTSkip("No stable foreign-owned directory is available on this host.")
        }
        let before = try? FileManager.default.contentsOfDirectory(atPath: foreignRoot.path)
        let store = PluginStorage(configuration: .init(rootDirectoryURL: foreignRoot))
        await assertFailure(.readFailed) { try await store.get(pluginID: self.alpha, key: "safe") }
        await assertFailure(.readFailed) { try await store.set(pluginID: self.alpha, key: "safe", value: .number(2)) }
        if let before { XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: foreignRoot.path), before) }
    }

    func testAtomicReplacementFailurePreservesCommittedBytesAndRemovesTemporaryFile() async throws {
        let workspace = try StorageWorkspace()
        defer { workspace.remove() }
        let store = PluginStorage(configuration: workspace.configuration)
        try await store.set(pluginID: alpha, key: "safe", value: .string("previous"))
        let before = try Data(contentsOf: workspace.file(alpha))
        let replacer = StorageFailingReplacer()
        let failing = PluginStorage(configuration: workspace.configuration, replacer: replacer)
        await assertFailure(.writeFailed) { try await failing.set(pluginID: self.alpha, key: "safe", value: .string("replacement")) }
        XCTAssertEqual(replacer.calls, 1)
        XCTAssertEqual(replacer.preparedMode, 0o600)
        XCTAssertFalse(replacer.wasOnMainThread)
        XCTAssertEqual(try Data(contentsOf: workspace.file(alpha)), before)
        try await assertValue(failing, pluginID: alpha, key: "safe", equals: .string("previous"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workspace.configuration.directoryURL.path), ["\(alpha).json"])

        let fixture = StorageRuntimeFixture(store: failing)
        defer { fixture.shutdown() }
        let runtime = fixture.load(try package(id: alpha, source: """
            function onStart() {
                island.storage.set('safe', 'replacement').catch(error => {
                    globalThis.code = error.code; globalThis.message = error.message; globalThis.done = true;
                });
            }
            """))
        try await marker(runtime, "done")
        try await assertJavaScript(runtime, "code", equals: .string("storageWriteFailed"))
        try await assertJavaScript(runtime, "message", equals: .string("Plugin storage could not be written."))
        XCTAssertEqual(try Data(contentsOf: workspace.file(alpha)), before)
    }

    func testRevocationDuringDiskPreparationPreventsCommitAndMainActorRemainsResponsive() async throws {
        let workspace = try StorageWorkspace()
        defer { workspace.remove() }
        let baseline = PluginStorage(configuration: workspace.configuration)
        try await baseline.set(pluginID: alpha, key: "safe", value: .string("previous"))
        let before = try Data(contentsOf: workspace.file(alpha))
        let gate = StorageIOGate()
        let admission = PluginStorageAdmission()
        let store = PluginStorage(configuration: workspace.configuration, ioObserver: { gate.observe() })
        let operation = Task {
            try await store.set(pluginID: alpha, key: "safe", value: .string("replacement"), admission: admission)
        }
        try await waitForIO(gate)
        XCTAssertFalse(gate.wasOnMainThread)
        admission.revoke()
        gate.release()
        await assertFailure(.inactiveExecution) { try await operation.value }
        XCTAssertEqual(try Data(contentsOf: workspace.file(alpha)), before)
        let committed = PluginStorageAdmission()
        try await baseline.set(pluginID: alpha, key: "safe", value: .string("committed"), admission: committed)
        committed.revoke()
        await assertFailure(.inactiveExecution) { try await baseline.get(pluginID: self.alpha, key: "safe", admission: committed) }
        try await assertValue(PluginStorage(configuration: workspace.configuration), pluginID: alpha, key: "safe", equals: .string("committed"))
    }

    func testLifecycleDisableReenableRevokesPreparedWriteAndOldContext() async throws {
        let workspace = try StorageWorkspace()
        defer { workspace.remove() }
        let baseline = PluginStorage(configuration: workspace.configuration)
        try await baseline.set(pluginID: alpha, key: "safe", value: .string("previous"))
        let before = try Data(contentsOf: workspace.file(alpha))
        let gate = StorageIOGate()
        let store = PluginStorage(configuration: workspace.configuration, ioObserver: { gate.observe() })
        let fixture = StorageRuntimeFixture(store: store)
        defer { fixture.shutdown(); gate.release() }
        let package = try package(id: alpha, source: """
            function onStart() { globalThis.started = true; }
            function writeForTesting() { island.storage.set('stale', 1).catch(() => {}); }
            """)
        let oldRuntime = fixture.load(package)
        try await marker(oldRuntime, "started")
        let oldContext = try XCTUnwrap(fixture.contexts.last)
        _ = try await oldRuntime.evaluateForTesting("writeForTesting(); void 0")
        try await waitForIO(gate)
        XCTAssertFalse(gate.wasOnMainThread)
        fixture.lifecycle.pluginDidChangeEnablement(id: alpha, isEnabled: false)
        fixture.lifecycle.pluginDidChangeEnablement(id: alpha, isEnabled: true)
        let newRuntime = try XCTUnwrap(fixture.runtimes.last)
        XCTAssertFalse(newRuntime === oldRuntime)
        let staleResponse = await fixture.service.handle(
            "{\"apiVersion\":\"1.0.0\",\"method\":\"storage.set\",\"params\":{\"key\":\"stale\",\"value\":2}}",
            package: package, context: oldContext)
        XCTAssertEqual(try bridgeErrorCode(staleResponse), "inactiveExecution")
        gate.release()
        try await marker(newRuntime, "started")
        _ = try await newRuntime.evaluateForTesting("island.storage.get('stale').then(value => {globalThis.clean=value===null; globalThis.done=true;}); void 0")
        try await marker(newRuntime, "done")
        try await assertJavaScript(newRuntime, "clean", equals: .boolean(true))
        XCTAssertEqual(try Data(contentsOf: workspace.file(alpha)), before)
        XCTAssertEqual(fixture.lifecycle.snapshot(id: alpha)?.state, .running)
    }

    func testDirectRuntimeTeardownRevokesPreparedWriteBeforeCommit() async throws {
        let workspace = try StorageWorkspace()
        defer { workspace.remove() }
        let baseline = PluginStorage(configuration: workspace.configuration)
        try await baseline.set(pluginID: alpha, key: "safe", value: .string("previous"))
        let before = try Data(contentsOf: workspace.file(alpha))
        let gate = StorageIOGate()
        let store = PluginStorage(configuration: workspace.configuration, ioObserver: { gate.observe() })
        let fixture = StorageRuntimeFixture(store: store)
        defer { fixture.shutdown(); gate.release() }
        let package = try package(id: alpha, source: """
            function onStart() { globalThis.started = true; }
            function writeForTesting() { island.storage.set('stale', 1).catch(() => {}); }
            """)
        let runtime = fixture.load(package)
        try await marker(runtime, "started")
        let context = try XCTUnwrap(fixture.contexts.last)
        _ = try await runtime.evaluateForTesting("writeForTesting(); void 0")
        try await waitForIO(gate)
        XCTAssertFalse(gate.wasOnMainThread)
        runtime.teardown()
        gate.release()
        // The read shares this Store actor and completes after the prepared set.
        try await assertValue(store, pluginID: alpha, key: "stale", equals: .null)
        let staleResponse = await fixture.service.handle(
            "{\"apiVersion\":\"1.0.0\",\"method\":\"storage.get\",\"params\":{\"key\":\"safe\"}}",
            package: package, context: context)
        XCTAssertEqual(try bridgeErrorCode(staleResponse), "inactiveExecution")
        XCTAssertEqual(try Data(contentsOf: workspace.file(alpha)), before)
    }

    private func waitForIO(_ gate: StorageIOGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !gate.hasEntered {
            guard ContinuousClock.now < deadline else {
                gate.release()
                throw StorageTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func bridgeErrorCode(_ json: String) throws -> String? {
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return (response["error"] as? [String: Any])?["code"] as? String
    }

    private func assertCorruptFile(_ data: Data, file: StaticString = #filePath, line: UInt = #line) async throws {
        let workspace = try StorageWorkspace()
        defer { workspace.remove() }
        let store = PluginStorage(configuration: workspace.configuration)
        try await store.set(pluginID: alpha, key: "safe", value: .number(1))
        try workspace.seed(data, pluginID: alpha)
        await assertFailure(.readFailed, file: file, line: line) { try await store.get(pluginID: self.alpha, key: "safe") }
        await assertFailure(.readFailed, file: file, line: line) { try await store.set(pluginID: self.alpha, key: "safe", value: .number(2)) }
        await assertFailure(.readFailed, file: file, line: line) { try await store.clear(pluginID: self.alpha) }
        XCTAssertEqual(try Data(contentsOf: workspace.file(alpha)), data, file: file, line: line)
    }

    private func assertValue(_ store: PluginStorage, pluginID: String, key: String, equals expected: PluginBridgeJSON,
                             file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await store.get(pluginID: pluginID, key: key)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func assertFailure<T>(_ expected: PluginStorageError, file: StaticString = #filePath, line: UInt = #line,
                                  _ operation: () async throws -> T) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PluginStorageError, expected, file: file, line: line)
        }
    }

    private func permissions(_ url: URL) throws -> mode_t {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw StorageTestError.filesystem }
        return status.st_mode & 0o777
    }

    private func package(id: String, source: String) throws -> ValidatedPluginPackage {
        let manifest = try PluginManifest(id: id, name: "Storage Test", version: SemanticVersion("1.0.0"),
            engine: .javaScriptCore, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"),
            permissions: [.localStorage], capabilities: [.localStorage])
        let bytes = Data(source.utf8)
        return .init(manifest: manifest, canonicalRootURL: URL(fileURLWithPath: "/storage-tests/\(id)", isDirectory: true),
            entryRelativePath: "index.js", entrySource: bytes, regularFileCount: 2, totalFileBytes: UInt64(bytes.count))
    }

    private func marker(_ runtime: PluginRuntime, _ name: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while runtime.snapshot.state != .running {
            guard runtime.snapshot.lastFailure == nil, ContinuousClock.now < deadline else { throw StorageTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        while try await runtime.evaluateForTesting("globalThis['\(name)'] === true") != .boolean(true) {
            guard ContinuousClock.now < deadline else { throw StorageTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func assertJavaScript(_ runtime: PluginRuntime, _ source: String, equals expected: PluginJavaScriptValue) async throws {
        let actual = try await runtime.evaluateForTesting(source)
        XCTAssertEqual(actual, expected)
    }
}

private struct StorageWorkspace {
    let configuration: PluginStorageConfiguration

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PluginStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        configuration = .init(rootDirectoryURL: root)
    }

    func file(_ id: String) throws -> URL { try configuration.namespaceFileURL(pluginID: id) }
    func remove() { try? FileManager.default.removeItem(at: configuration.rootDirectoryURL) }
    func seed(_ data: Data, pluginID: String) throws {
        if !FileManager.default.fileExists(atPath: configuration.directoryURL.path) {
            try FileManager.default.createDirectory(at: configuration.directoryURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let url = try file(pluginID)
        try data.write(to: url)
        guard chmod(url.path, 0o600) == 0 else { throw StorageTestError.filesystem }
    }
}

@MainActor
private final class StorageRuntimeFixture {
    let service: PluginJSBridge
    let lifecycle: PluginLifecycleBridge
    private let factory = StorageRuntimeFactory()
    var contexts: [PluginExecutionContext] { factory.contexts }
    var runtimes: [PluginRuntime] { factory.runtimes }

    init(store: PluginStorage) {
        let service = PluginJSBridge(storage: store)
        self.service = service
        let manager = ActivityManager(clock: TestActivityClock(Date(timeIntervalSinceReferenceDate: 98_000)), configuration: .immediate)
        let factory = factory
        lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: ActionRouter(manager: manager)) { package in
            let runtime = PluginRuntime(package: package, bridge: service)
            factory.runtimes.append(runtime)
            return StorageRuntimeForwarder(runtime: runtime, factory: factory)
        }
    }

    func load(_ package: ValidatedPluginPackage) -> PluginRuntime {
        lifecycle.pluginDidLoad(package, isEnabled: true)
        return factory.runtimes.last!
    }
    func shutdown() { lifecycle.shutdown() }
}

@MainActor
private final class StorageRuntimeFactory {
    var runtimes: [PluginRuntime] = []
    var contexts: [PluginExecutionContext] = []
}

@MainActor
private final class StorageRuntimeForwarder: PluginLifecycleRuntime {
    let runtime: PluginRuntime
    let factory: StorageRuntimeFactory
    init(runtime: PluginRuntime, factory: StorageRuntimeFactory) { self.runtime = runtime; self.factory = factory }
    func onStart(context: PluginExecutionContext) throws { factory.contexts.append(context); try runtime.onStart(context: context) }
    func onStop(reason: PluginStopReason) throws { try runtime.onStop(reason: reason) }
    func teardown() { runtime.teardown() }
}

private nonisolated final class StorageFailingReplacer: PluginStorageFileReplacing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls = 0
    private var storedPreparedMode: mode_t = 0
    private var storedMainThread = false
    var calls: Int { lock.withLock { storedCalls } }
    var preparedMode: mode_t { lock.withLock { storedPreparedMode } }
    var wasOnMainThread: Bool { lock.withLock { storedMainThread } }

    func replace(preparedFile: URL, destination: URL, directoryDescriptor: Int32) throws {
        var status = stat()
        guard lstat(preparedFile.path, &status) == 0 else { throw StorageTestError.filesystem }
        lock.withLock {
            storedCalls += 1
            storedPreparedMode = status.st_mode & 0o777
            storedMainThread = Thread.isMainThread
        }
        throw StorageTestError.injectedWriteFailure
    }
}

private nonisolated final class StorageIOGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var observed = false
    private var storedMainThread = false
    var hasEntered: Bool { lock.withLock { observed } }
    var wasOnMainThread: Bool { lock.withLock { storedMainThread } }

    func observe() {
        let block = lock.withLock {
            guard !observed else { return false }
            observed = true
            storedMainThread = Thread.isMainThread
            return true
        }
        guard block else { return }
        _ = semaphore.wait(timeout: .now() + 5)
    }
    func release() { semaphore.signal() }
}

private nonisolated enum StorageTestError: Error { case timedOut, filesystem, injectedWriteFailure }
