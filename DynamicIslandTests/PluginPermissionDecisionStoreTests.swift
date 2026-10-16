import Darwin
import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginPermissionDecisionStoreTests: XCTestCase {
    private let alpha = "com.example.permissions.alpha"
    private let beta = "com.example.permissions.beta"
    private let firstFingerprint = String(repeating: "a", count: 64)
    private let secondFingerprint = String(repeating: "b", count: 64)

    func testDiskDecisionsSurviveNewActorAndAllKnownStatesRoundTrip() async throws {
        let workspace = try PermissionStoreWorkspace()
        defer { workspace.remove() }
        let store = PluginPermissionDecisionStore(configuration: workspace.configuration)
        let declarations = Dictionary(uniqueKeysWithValues: PluginPermission.allCases.map { ($0, PluginPermissionState.requested) })
        try await store.replace(record: record(states: declarations))
        for (index, permission) in PluginPermission.allCases.enumerated() {
            try await store.setDecision(pluginID: alpha, fingerprint: firstFingerprint, permission: permission,
                                        state: PluginPermissionState.allCases[index % 4])
        }
        try await store.replace(record: record(id: beta, states: [:]))
        let snapshot = try await store.load()
        let restarted = PluginPermissionDecisionStore(configuration: workspace.configuration)
        let restored = try await restarted.load()
        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(restored[alpha]?.states.count, PluginPermission.allCases.count)
        XCTAssertEqual(restored[beta]?.states, [:])
        XCTAssertEqual(try permissions(workspace.configuration.rootDirectoryURL), 0o700)
        XCTAssertEqual(try permissions(workspace.configuration.directoryURL), 0o700)
        XCTAssertEqual(try permissions(workspace.file), 0o600)
        var status = stat()
        XCTAssertEqual(lstat(workspace.file.path, &status), 0)
        XCTAssertEqual(status.st_uid, geteuid())
        XCTAssertEqual(status.st_nlink, 1)
    }

    func testMissingDiskFileStartsEmptyWithoutCreatingDecisionFile() async throws {
        let workspace = try PermissionStoreWorkspace()
        defer { workspace.remove() }
        try FileManager.default.removeItem(at: workspace.configuration.rootDirectoryURL)
        let store = PluginPermissionDecisionStore(configuration: workspace.configuration)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.file.path))
        XCTAssertEqual(try permissions(workspace.configuration.directoryURL), 0o700)
    }

    func testInitialAndReplacementCodeCannotImportGrants() async throws {
        let store = PluginPermissionDecisionStore()
        await assertFailure(.invalidArguments) { try await store.replace(record: self.record(states: [.network: .granted])) }
        let empty = try await store.load()
        XCTAssertTrue(empty.isEmpty)
        try await store.replace(record: record())
        try await store.setDecision(pluginID: alpha, fingerprint: firstFingerprint, permission: .network, state: .granted)
        await assertFailure(.invalidArguments) {
            try await store.replace(record: self.record(fingerprint: self.secondFingerprint, states: [.network: .granted]))
        }
        let previous = try await store.load()
        XCTAssertEqual(previous[alpha]?.states[.network], .granted)
        try await store.replace(record: record(fingerprint: secondFingerprint, states: [.network: .requested, .localStorage: .requested]))
        let replacement = try await store.load()
        XCTAssertEqual(replacement[alpha]?.fingerprint, secondFingerprint)
        XCTAssertEqual(replacement[alpha]?.states, [.network: .requested, .localStorage: .requested])
        // Returning to earlier code starts requested; old approval is gone.
        try await store.replace(record: record())
        let reverted = try await store.load()
        XCTAssertEqual(reverted[alpha]?.states[.network], .requested)
    }

    func testStaleDecisionCannotOverwriteNewPackageOrRecreateRemovedRecord() async throws {
        let workspace = try PermissionStoreWorkspace()
        defer { workspace.remove() }
        let store = PluginPermissionDecisionStore(configuration: workspace.configuration)
        try await store.replace(record: record())
        try await store.replace(record: record(fingerprint: secondFingerprint))
        let before = try Data(contentsOf: workspace.file)
        await assertFailure(.stalePackage) {
            try await store.setDecision(pluginID: self.alpha, fingerprint: self.firstFingerprint, permission: .network, state: .granted)
        }
        XCTAssertEqual(try Data(contentsOf: workspace.file), before)
        try await store.remove(pluginID: alpha)
        await assertFailure(.stalePackage) {
            try await store.setDecision(pluginID: self.alpha, fingerprint: self.secondFingerprint, permission: .network, state: .granted)
        }
        let restored = try await PluginPermissionDecisionStore(configuration: workspace.configuration).load()
        XCTAssertNil(restored[alpha])
    }

    func testDecisionCannotAddUndeclaredPermissionAndRequestedResetsExplicitGrant() async throws {
        let store = PluginPermissionDecisionStore()
        try await store.replace(record: record())
        await assertFailure(.invalidArguments) {
            try await store.setDecision(pluginID: self.alpha, fingerprint: self.firstFingerprint, permission: .readClipboard, state: .granted)
        }
        try await store.setDecision(pluginID: alpha, fingerprint: firstFingerprint, permission: .network, state: .granted)
        try await store.setDecision(pluginID: alpha, fingerprint: firstFingerprint, permission: .network, state: .requested)
        let loaded = try await store.load()
        XCTAssertEqual(loaded[alpha]?.states, [.network: .requested])
    }

    func testMemoryResultsAreIndependentValueCopiesAndRemovalKeepsOtherPlugin() async throws {
        let store = PluginPermissionDecisionStore()
        try await store.replace(record: record())
        try await store.replace(record: record(id: beta))
        var copy = try await store.load()
        copy.removeValue(forKey: alpha)
        let actual = try await store.load()
        XCTAssertNotNil(actual[alpha])
        try await store.remove(pluginID: alpha)
        let removed = try await store.load()
        XCTAssertNil(removed[alpha])
        XCTAssertNotNil(removed[beta])
        try await store.remove(pluginID: alpha)
    }

    func testInvalidIdentityAndFingerprintsNeverCreateFiles() async throws {
        let workspace = try PermissionStoreWorkspace()
        defer { workspace.remove() }
        let store = PluginPermissionDecisionStore(configuration: workspace.configuration)
        for id in ["../escape", "single", "Upper.example.plugin", "com.example/escape", "com.example.-plugin"] {
            await assertFailure(.invalidArguments) { try await store.replace(record: self.record(id: id)) }
            await assertFailure(.invalidArguments) { try await store.remove(pluginID: id) }
        }
        for fingerprint in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                            String(repeating: "A", count: 64), String(repeating: "g", count: 64), String(repeating: "界", count: 64)] {
            await assertFailure(.invalidArguments) { try await store.replace(record: self.record(fingerprint: fingerprint)) }
            await assertFailure(.invalidArguments) {
                try await store.setDecision(pluginID: self.alpha, fingerprint: fingerprint, permission: .network, state: .granted)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.file.path))
    }

    func testRecordQuotaAllowsOverwriteAndRemovalWithoutPartialChange() async throws {
        let store = PluginPermissionDecisionStore()
        for index in 0..<128 { try await store.replace(record: record(id: "com.example.plugin\(index)")) }
        await assertFailure(.quotaExceeded) { try await store.replace(record: self.record(id: "com.example.overflow")) }
        try await store.setDecision(pluginID: "com.example.plugin0", fingerprint: firstFingerprint, permission: .network, state: .denied)
        try await store.remove(pluginID: "com.example.plugin1")
        try await store.replace(record: record(id: "com.example.replacement"))
        let loaded = try await store.load()
        XCTAssertEqual(loaded.count, 128)
        XCTAssertNil(loaded["com.example.overflow"])
        XCTAssertEqual(loaded["com.example.plugin0"]?.states[.network], .denied)
    }

    func testMaximumRecordCountAndIdentityLengthDecodeWithAllPermissions() async throws {
        let workspace = try PermissionStoreWorkspace()
        defer { workspace.remove() }
        let states = Dictionary(uniqueKeysWithValues: PluginPermission.allCases.map { ($0.rawValue, "granted") })
        let records = Dictionary(uniqueKeysWithValues: (0..<128).map { index in
            let suffix = String(repeating: "z", count: 59 - String(index).count) + String(index)
            let id = (["com"] + ["x", "y", "z"].map { String(repeating: $0, count: 63) } + [suffix]).joined(separator: ".")
            XCTAssertEqual(id.utf8.count, 255)
            return (id, ["pluginID": id, "fingerprint": firstFingerprint, "states": states] as [String: Any])
        })
        let bytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "records": records])
        XCTAssertLessThan(bytes.count, 131_072)
        try workspace.seed(bytes)
        let store = PluginPermissionDecisionStore(configuration: workspace.configuration)
        let restored = try await store.load()
        XCTAssertEqual(restored.count, 128)
        XCTAssertTrue(restored.values.allSatisfy { $0.states.count == PluginPermission.allCases.count && $0.states.values.allSatisfy { $0 == .granted } })
        let id = try XCTUnwrap(restored.keys.first)
        try await store.setDecision(pluginID: id, fingerprint: firstFingerprint, permission: .network, state: .revoked)
        let roundTrip = try await PluginPermissionDecisionStore(configuration: workspace.configuration).load()
        XCTAssertEqual(roundTrip[id]?.states[.network], .revoked)
    }

    func testSchemaDuplicatesUnknownFieldsAndStatesFailClosedWithoutOverwriting() async throws {
        let validRecord = "\"\(alpha)\":{\"pluginID\":\"\(alpha)\",\"fingerprint\":\"\(firstFingerprint)\",\"states\":{\"network\":\"granted\"}}"
        let malformed = [
            "{\"schemaVersion\":2,\"records\":{}}",
            "{\"schemaVersion\":1,\"schemaVersion\":1,\"records\":{}}",
            "{\"schemaVersion\":1,\"records\":{},\"unknown\":true}",
            "{\"schemaVersion\":1,\"records\":{\(validRecord),\(validRecord)}}",
            "{\"schemaVersion\":1,\"records\":{\(validRecord.replacingOccurrences(of: "\"states\":", with: "\"unknown\":true,\"states\":"))}}",
            "{\"schemaVersion\":1,\"records\":{\(validRecord.replacingOccurrences(of: "\"network\":\"granted\"", with: "\"network\":\"granted\",\"network\":\"denied\""))}}",
            "{\"schemaVersion\":1,\"records\":{\(validRecord.replacingOccurrences(of: "\"network\":\"granted\"", with: "\"future.permission\":\"granted\""))}}",
            "{\"schemaVersion\":1,\"records\":{\(validRecord.replacingOccurrences(of: "\"granted\"", with: "\"allowed\""))}}",
            "{\"schemaVersion\":1,\"records\":{\(validRecord.replacingOccurrences(of: "\"pluginID\":\"\(alpha)\"", with: "\"pluginID\":\"\(beta)\""))}}",
            "{\"schemaVersion\":1,\"records\":{\(validRecord.replacingOccurrences(of: firstFingerprint, with: "invalid"))}}",
            "{\"schemaVersion\":1,\"records\":[]}",
            "{\"schemaVersion\":1,\"records\":{\"../escape\":{\"pluginID\":\"../escape\",\"fingerprint\":\"\(firstFingerprint)\",\"states\":{}}}}"
        ]
        for source in malformed { try await assertCorrupt(Data(source.utf8)) }
    }

    func testOversizedUTF8AndTooManyRecordsRejectBeforeAnyRecoveryWrite() async throws {
        try await assertCorrupt(Data(repeating: 32, count: 131_073))
        try await assertCorrupt(Data([0xff, 0xfe, 0x00]))
        let records = Dictionary(uniqueKeysWithValues: (0..<129).map { index in
            let id = "com.example.plugin\(index)"
            return (id, ["pluginID": id, "fingerprint": firstFingerprint, "states": [:]] as [String: Any])
        })
        try await assertCorrupt(JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "records": records]))
    }

    func testExternalCorruptionAfterSuccessfulLoadCannotBeHiddenByCachedState() async throws {
        let workspace = try PermissionStoreWorkspace()
        defer { workspace.remove() }
        let store = PluginPermissionDecisionStore(configuration: workspace.configuration)
        try await store.replace(record: record())
        _ = try await store.load()
        let corrupt = Data("{\"schemaVersion\":2,\"records\":{}}".utf8)
        try workspace.seed(corrupt)
        await assertFailure(.readFailed) { try await store.load() }
        await assertFailure(.readFailed) {
            try await store.setDecision(pluginID: self.alpha, fingerprint: self.firstFingerprint, permission: .network, state: .granted)
        }
        XCTAssertEqual(try Data(contentsOf: workspace.file), corrupt)
    }

    func testSymlinkHardlinkAndInsecureFileModesNeverReadOrOverwriteTargets() async throws {
        for kind in ["symlink", "hardlink", "mode"] {
            let workspace = try PermissionStoreWorkspace()
            defer { workspace.remove() }
            let store = PluginPermissionDecisionStore(configuration: workspace.configuration)
            try await store.replace(record: record())
            let before = try Data(contentsOf: workspace.file)
            let external = workspace.configuration.rootDirectoryURL.appendingPathComponent("external.json")
            try before.write(to: external)
            XCTAssertEqual(chmod(external.path, 0o600), 0)
            if kind == "symlink" {
                try FileManager.default.removeItem(at: workspace.file)
                try FileManager.default.createSymbolicLink(at: workspace.file, withDestinationURL: external)
            } else if kind == "hardlink" {
                try FileManager.default.removeItem(at: workspace.file)
                XCTAssertEqual(link(external.path, workspace.file.path), 0)
            } else { XCTAssertEqual(chmod(workspace.file.path, 0o666), 0) }
            await assertFailure(.readFailed) { try await store.load() }
            await assertFailure(.readFailed) { try await store.replace(record: self.record()) }
            await assertFailure(.readFailed) { try await store.remove(pluginID: self.alpha) }
            XCTAssertEqual(try Data(contentsOf: external), before)
        }
    }

    func testSymlinkAndWritableStateDirectoriesFailClosed() async throws {
        for kind in ["symlink", "mode"] {
            let workspace = try PermissionStoreWorkspace()
            defer { workspace.remove() }
            let external = workspace.configuration.rootDirectoryURL.appendingPathComponent("external", isDirectory: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
            if kind == "symlink" {
                try FileManager.default.createSymbolicLink(at: workspace.configuration.directoryURL, withDestinationURL: external)
            } else {
                try FileManager.default.createDirectory(at: workspace.configuration.directoryURL, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: NSNumber(value: 0o777)])
                XCTAssertEqual(chmod(workspace.configuration.directoryURL.path, 0o777), 0)
            }
            let store = PluginPermissionDecisionStore(configuration: workspace.configuration)
            await assertFailure(.readFailed) { try await store.load() }
            await assertFailure(.readFailed) { try await store.replace(record: self.record()) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
        }
    }

    func testFIFOAndDirectoryAtDecisionFileNeverBlockOrBecomeValidState() async throws {
        for kind in ["fifo", "directory"] {
            let workspace = try PermissionStoreWorkspace()
            defer { workspace.remove() }
            try FileManager.default.createDirectory(at: workspace.configuration.directoryURL, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
            if kind == "fifo" { XCTAssertEqual(mkfifo(workspace.file.path, 0o600), 0) }
            else {
                try FileManager.default.createDirectory(at: workspace.file, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: NSNumber(value: 0o700)])
            }
            let store = PluginPermissionDecisionStore(configuration: workspace.configuration)
            await assertFailure(.readFailed) { try await store.load() }
            await assertFailure(.readFailed) { try await store.replace(record: self.record()) }
            var status = stat()
            XCTAssertEqual(lstat(workspace.file.path, &status), 0)
            XCTAssertEqual(status.st_mode & S_IFMT, kind == "fifo" ? S_IFIFO : S_IFDIR)
        }
    }

    func testSymlinkRootAndForeignOwnerRootAreRejected() async throws {
        let workspace = try PermissionStoreWorkspace()
        defer { workspace.remove() }
        let alias = workspace.configuration.rootDirectoryURL.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: workspace.configuration.rootDirectoryURL)
        let symlink = PluginPermissionDecisionStore(configuration: .init(rootDirectoryURL: alias))
        await assertFailure(.readFailed) { try await symlink.load() }
        await assertFailure(.readFailed) { try await symlink.replace(record: self.record()) }
        let foreign = URL(fileURLWithPath: "/private/var/empty", isDirectory: true)
        var status = stat()
        if lstat(foreign.path, &status) == 0, status.st_uid != geteuid() {
            let store = PluginPermissionDecisionStore(configuration: .init(rootDirectoryURL: foreign))
            await assertFailure(.readFailed) { try await store.load() }
            await assertFailure(.readFailed) { try await store.replace(record: self.record()) }
        }
    }

    func testAtomicReplacementFailurePreservesPreviousDecisionsAndCleansTemporaryFile() async throws {
        let workspace = try PermissionStoreWorkspace()
        defer { workspace.remove() }
        let store = PluginPermissionDecisionStore(configuration: workspace.configuration)
        try await store.replace(record: record())
        try await store.setDecision(pluginID: alpha, fingerprint: firstFingerprint, permission: .network, state: .denied)
        let before = try Data(contentsOf: workspace.file)
        let replacer = PermissionStoreFailingReplacer()
        let failing = PluginPermissionDecisionStore(configuration: workspace.configuration, replacer: replacer)
        await assertFailure(.writeFailed) {
            try await failing.setDecision(pluginID: self.alpha, fingerprint: self.firstFingerprint, permission: .network, state: .granted)
        }
        XCTAssertEqual(replacer.calls, 1)
        XCTAssertEqual(replacer.preparedMode, 0o600)
        XCTAssertFalse(replacer.wasOnMainThread)
        XCTAssertEqual(try Data(contentsOf: workspace.file), before)
        let loaded = try await failing.load()
        XCTAssertEqual(loaded[alpha]?.states[.network], .denied)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workspace.configuration.directoryURL.path),
                       [workspace.file.lastPathComponent])
        await assertFailure(.writeFailed) { try await failing.remove(pluginID: self.alpha) }
        XCTAssertEqual(try Data(contentsOf: workspace.file), before)
    }

    private func record(id: String? = nil, fingerprint: String? = nil,
                        states: [PluginPermission: PluginPermissionState] = [.network: .requested]) -> PluginPermissionDecisionRecord {
        .init(pluginID: id ?? alpha, fingerprint: fingerprint ?? firstFingerprint, states: states)
    }

    private func assertFailure<T>(_ expected: PluginPermissionDecisionStoreError,
                                  file: StaticString = #filePath, line: UInt = #line,
                                  _ body: () async throws -> T) async {
        do { _ = try await body(); XCTFail("Expected fixed permission persistence error.", file: file, line: line) }
        catch let error as PluginPermissionDecisionStoreError { XCTAssertEqual(error, expected, file: file, line: line) }
        catch { XCTFail("Unexpected error type.", file: file, line: line) }
    }

    private func assertCorrupt(_ bytes: Data) async throws {
        let workspace = try PermissionStoreWorkspace()
        defer { workspace.remove() }
        try workspace.seed(bytes)
        let store = PluginPermissionDecisionStore(configuration: workspace.configuration)
        await assertFailure(.readFailed) { try await store.load() }
        await assertFailure(.readFailed) { try await store.replace(record: self.record()) }
        await assertFailure(.readFailed) {
            try await store.setDecision(pluginID: self.alpha, fingerprint: self.firstFingerprint, permission: .network, state: .granted)
        }
        await assertFailure(.readFailed) { try await store.remove(pluginID: self.alpha) }
        XCTAssertEqual(try Data(contentsOf: workspace.file), bytes)
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}

private struct PermissionStoreWorkspace {
    let configuration: PluginPermissionDecisionStoreConfiguration
    var file: URL { configuration.fileURL }

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-permission-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        configuration = .init(rootDirectoryURL: root)
    }

    func seed(_ bytes: Data) throws {
        try FileManager.default.createDirectory(at: configuration.directoryURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try bytes.write(to: file)
        guard chmod(file.path, 0o600) == 0 else { throw PluginPermissionDecisionStoreError.writeFailed }
    }

    func remove() { try? FileManager.default.removeItem(at: configuration.rootDirectoryURL) }
}

private nonisolated final class PermissionStoreFailingReplacer: PluginPermissionDecisionFileReplacing, @unchecked Sendable {
    private let lock = NSLock()
    private var observedCalls = 0
    private var observedMode = 0
    private var observedMainThread = false

    var calls: Int { lock.lock(); defer { lock.unlock() }; return observedCalls }
    var preparedMode: Int { lock.lock(); defer { lock.unlock() }; return observedMode }
    var wasOnMainThread: Bool { lock.lock(); defer { lock.unlock() }; return observedMainThread }

    func replace(preparedFile: URL, destination: URL, directoryDescriptor: Int32) throws {
        var status = stat()
        _ = fstatat(directoryDescriptor, preparedFile.lastPathComponent, &status, AT_SYMLINK_NOFOLLOW)
        lock.lock()
        observedCalls += 1
        observedMode = Int(status.st_mode & 0o777)
        observedMainThread = Thread.isMainThread
        lock.unlock()
        throw PluginPermissionDecisionStoreError.writeFailed
    }
}
