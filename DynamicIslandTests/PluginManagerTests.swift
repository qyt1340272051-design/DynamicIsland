import Darwin
import Foundation
import XCTest
@testable import DynamicIsland

final class PluginManagerTests: XCTestCase {
    func testDiscoveryIsolatesInvalidSiblingAndKeepsImmutableEntrySnapshot() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.remove() }
        let manager = PluginManager(configuration: workspace.configuration)
        try await prepareInstalledDirectory(with: manager)

        let source = "throw new Error('discovery must not execute plugin code')"
        let valid = try makePackage(
            in: workspace.configuration.installedDirectoryURL,
            directoryName: "AlphaPlugin",
            id: "com.example.alpha",
            entrySource: source
        )
        let invalid = try makePackage(
            in: workspace.configuration.installedDirectoryURL,
            directoryName: "BrokenPlugin",
            id: "com.example.broken"
        )
        try FileManager.default.removeItem(at: invalid.entryURL)

        let report = await manager.discover()

        XCTAssertEqual(report.plugins.map(\.id), ["com.example.alpha"])
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.candidateName, "BrokenPlugin")
        XCTAssertEqual(report.failures.first?.error.code, "entryMissing")

        let discoveredPackage = await manager.validatedPackage(id: "com.example.alpha")
        let snapshot = try XCTUnwrap(discoveredPackage)
        XCTAssertEqual(snapshot.entrySource, Data(source.utf8))

        try Data("changed after discovery".utf8).write(to: valid.entryURL)
        let packageAfterMutation = await manager.validatedPackage(id: "com.example.alpha")
        let unchanged = try XCTUnwrap(packageAfterMutation)
        XCTAssertEqual(unchanged.entrySource, Data(source.utf8))
    }

    func testDiscoveryRejectsEveryPackageInDuplicateIDGroup() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.remove() }
        let manager = PluginManager(configuration: workspace.configuration)
        try await prepareInstalledDirectory(with: manager)

        let duplicateID = "com.example.duplicate"
        try makePackage(
            in: workspace.configuration.installedDirectoryURL,
            directoryName: "FirstPlugin",
            id: duplicateID
        )
        try makePackage(
            in: workspace.configuration.installedDirectoryURL,
            directoryName: "SecondPlugin",
            id: duplicateID
        )

        let report = await manager.discover()

        XCTAssertTrue(report.plugins.isEmpty)
        XCTAssertEqual(report.failures.map(\.candidateName), ["FirstPlugin", "SecondPlugin"])
        XCTAssertEqual(report.failures.map(\.pluginID), [duplicateID, duplicateID])
        XCTAssertEqual(report.failures.map(\.error.code), ["duplicatePluginID", "duplicatePluginID"])
    }

    func testPluginsEnableIndependentlyAndRestoreExactVersionAfterRestart() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.remove() }
        let firstManager = PluginManager(configuration: workspace.configuration)
        try await prepareInstalledDirectory(with: firstManager)

        try makePackage(
            in: workspace.configuration.installedDirectoryURL,
            directoryName: "AlphaPlugin",
            id: "com.example.alpha"
        )
        try makePackage(
            in: workspace.configuration.installedDirectoryURL,
            directoryName: "BetaPlugin",
            id: "com.example.beta"
        )
        _ = await firstManager.discover()

        let initial = await firstManager.plugins()
        XCTAssertEqual(initial.map(\.isEnabled), [false, false])

        _ = try await firstManager.enable(id: "com.example.alpha")
        _ = try await firstManager.enable(id: "com.example.beta")
        _ = try await firstManager.disable(id: "com.example.beta")

        let firstAlphaEnabled = await firstManager.isEnabled(id: "com.example.alpha")
        let firstBetaEnabled = await firstManager.isEnabled(id: "com.example.beta")
        XCTAssertTrue(firstAlphaEnabled)
        XCTAssertFalse(firstBetaEnabled)

        let restartedManager = PluginManager(configuration: workspace.configuration)
        let restored = await restartedManager.discover()

        XCTAssertTrue(restored.failures.isEmpty)
        XCTAssertEqual(restored.plugins.map(\.id), ["com.example.alpha", "com.example.beta"])
        XCTAssertEqual(restored.plugins.map(\.isEnabled), [true, false])
    }

    func testVersionChangeDisablesPluginDuringRestartDiscovery() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.remove() }
        let firstManager = PluginManager(configuration: workspace.configuration)
        try await prepareInstalledDirectory(with: firstManager)

        let package = try makePackage(
            in: workspace.configuration.installedDirectoryURL,
            directoryName: "VersionedPlugin",
            id: "com.example.versioned",
            version: "1.0.0"
        )
        _ = await firstManager.discover()
        _ = try await firstManager.enable(id: package.id)

        try writeManifest(
            to: package.manifestURL,
            id: package.id,
            version: "2.0.0"
        )

        let restartedManager = PluginManager(configuration: workspace.configuration)
        let report = await restartedManager.discover()

        XCTAssertTrue(report.failures.isEmpty)
        let record = try XCTUnwrap(report.plugins.first)
        XCTAssertEqual(record.manifest.version, try SemanticVersion("2.0.0"))
        XCTAssertFalse(record.isEnabled)
    }

    func testReloadUpdatesSnapshotAndFailedReloadKeepsLastValidRecord() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.remove() }
        let manager = PluginManager(configuration: workspace.configuration)
        try await prepareInstalledDirectory(with: manager)

        let originalSource = Data("export const value = 1".utf8)
        let updatedSource = Data("export const value = 2".utf8)
        let package = try makePackage(
            in: workspace.configuration.installedDirectoryURL,
            directoryName: "ReloadPlugin",
            id: "com.example.reload",
            entrySource: String(decoding: originalSource, as: UTF8.self)
        )
        _ = await manager.discover()
        _ = try await manager.enable(id: package.id)

        try updatedSource.write(to: package.entryURL)
        let reloaded = try await manager.reload(id: package.id)
        XCTAssertTrue(reloaded.isEnabled, "Entry-only changes preserve enablement when the manifest is unchanged")
        let packageAfterReload = await manager.validatedPackage(id: package.id)
        let updatedSnapshot = try XCTUnwrap(packageAfterReload)
        XCTAssertEqual(updatedSnapshot.entrySource, updatedSource)

        try FileManager.default.removeItem(at: package.entryURL)
        do {
            _ = try await manager.reload(id: package.id)
            XCTFail("Expected invalid reload to fail")
        } catch let error as PluginManagerError {
            XCTAssertEqual(error.code, "entryMissing")
        }

        let recordAfterFailedReload = await manager.plugin(id: package.id)
        let packageAfterFailedReload = await manager.validatedPackage(id: package.id)
        let retainedRecord = try XCTUnwrap(recordAfterFailedReload)
        let retainedSnapshot = try XCTUnwrap(packageAfterFailedReload)
        XCTAssertTrue(retainedRecord.isEnabled)
        XCTAssertEqual(retainedSnapshot.entrySource, updatedSource)
    }

    func testConcurrentLoadsReserveDuplicateIDAtomically() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.remove() }
        let manager = PluginManager(configuration: workspace.configuration)
        try await prepareInstalledDirectory(with: manager)

        let duplicateID = "com.example.concurrent"
        let first = try makePackage(
            in: workspace.configuration.installedDirectoryURL,
            directoryName: "ConcurrentOne",
            id: duplicateID
        )
        let second = try makePackage(
            in: workspace.configuration.installedDirectoryURL,
            directoryName: "ConcurrentTwo",
            id: duplicateID
        )

        async let firstResult = loadResult(manager: manager, packageURL: first.packageURL)
        async let secondResult = loadResult(manager: manager, packageURL: second.packageURL)
        let results = await [firstResult, secondResult]

        var successCount = 0
        var errors: [PluginManagerError] = []
        for result in results {
            switch result {
            case .success(let record):
                successCount += 1
                XCTAssertEqual(record.id, duplicateID)
            case .failure(let error):
                errors.append(error)
            }
        }

        XCTAssertEqual(successCount, 1)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.code, "duplicatePluginID")
        let loaded = await manager.plugins()
        XCTAssertEqual(loaded.map(\.id), [duplicateID])
    }

    func testUninstallRemovesOnlyTargetAndPersistsSiblingState() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.remove() }
        let manager = PluginManager(configuration: workspace.configuration)
        try await prepareInstalledDirectory(with: manager)

        let alpha = try makePackage(
            in: workspace.configuration.installedDirectoryURL,
            directoryName: "AlphaPlugin",
            id: "com.example.alpha"
        )
        let beta = try makePackage(
            in: workspace.configuration.installedDirectoryURL,
            directoryName: "BetaPlugin",
            id: "com.example.beta"
        )
        _ = await manager.discover()
        _ = try await manager.enable(id: alpha.id)
        _ = try await manager.enable(id: beta.id)

        let removed = try await manager.uninstall(id: alpha.id)

        XCTAssertEqual(removed.id, alpha.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: alpha.packageURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: beta.packageURL.path))
        let remaining = await manager.plugins()
        XCTAssertEqual(remaining.map(\.id), [beta.id])
        XCTAssertTrue(remaining.first?.isEnabled == true)

        let restartedManager = PluginManager(configuration: workspace.configuration)
        let restored = await restartedManager.discover()
        XCTAssertTrue(restored.failures.isEmpty)
        XCTAssertEqual(restored.plugins.map(\.id), [beta.id])
        XCTAssertTrue(restored.plugins.first?.isEnabled == true)
    }

    func testCorruptStateFailsClosedWithoutHidingValidPluginsAndIsRepaired() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.remove() }
        let firstManager = PluginManager(configuration: workspace.configuration)
        try await prepareInstalledDirectory(with: firstManager)

        let package = try makePackage(
            in: workspace.configuration.installedDirectoryURL,
            directoryName: "StatePlugin",
            id: "com.example.state"
        )
        _ = await firstManager.discover()
        _ = try await firstManager.enable(id: package.id)

        try Data("{".utf8).write(to: workspace.configuration.stateFileURL, options: .atomic)
        XCTAssertEqual(chmod(workspace.configuration.stateFileURL.path, S_IRUSR | S_IWUSR), 0)

        let restartedManager = PluginManager(configuration: workspace.configuration)
        let report = await restartedManager.discover()

        XCTAssertEqual(report.plugins.map(\.id), [package.id])
        XCTAssertFalse(report.plugins[0].isEnabled)
        XCTAssertTrue(report.failures.contains { $0.error == .stateReadFailed })

        let repairedData = try Data(contentsOf: workspace.configuration.stateFileURL)
        let repairedState = try JSONDecoder().decode(PluginManagerStateFile.self, from: repairedData)
        XCTAssertEqual(repairedState.plugins[package.id]?.version, try SemanticVersion("1.0.0"))
        XCTAssertFalse(repairedState.plugins[package.id]?.isEnabled == true)
    }

    func testStateWriteFailuresRollBackEnablementAndReloadSnapshot() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.remove() }
        let store = ControllableStateStore()
        let manager = PluginManager(
            configuration: workspace.configuration,
            stateStore: store
        )
        try await prepareInstalledDirectory(with: manager)

        let originalSource = Data("export const stable = true".utf8)
        let replacementSource = Data("export const stable = false".utf8)
        let package = try makePackage(
            in: workspace.configuration.installedDirectoryURL,
            directoryName: "RollbackPlugin",
            id: "com.example.rollback",
            entrySource: String(decoding: originalSource, as: UTF8.self)
        )
        _ = await manager.discover()
        _ = try await manager.enable(id: package.id)
        store.setSaveFailure(true)

        do {
            _ = try await manager.disable(id: package.id)
            XCTFail("Expected disable state write to fail")
        } catch let error as PluginManagerError {
            XCTAssertEqual(error, .stateWriteFailed)
        }
        let enabledAfterFailure = await manager.isEnabled(id: package.id)
        XCTAssertTrue(enabledAfterFailure)

        try replacementSource.write(to: package.entryURL)
        do {
            _ = try await manager.reload(id: package.id)
            XCTFail("Expected reload state write to fail")
        } catch let error as PluginManagerError {
            XCTAssertEqual(error, .stateWriteFailed)
        }

        let packageAfterFailedStateWrite = await manager.validatedPackage(id: package.id)
        let retained = try XCTUnwrap(packageAfterFailedStateWrite)
        XCTAssertEqual(retained.entrySource, originalSource)
        let stillEnabled = await manager.isEnabled(id: package.id)
        XCTAssertTrue(stillEnabled)
    }

    func testAtomicStateReplacementFailureKeepsOfficialBytesAndEnablement() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.remove() }
        let replacer = ControllableStateFileReplacer()
        let manager = PluginManager(
            configuration: workspace.configuration,
            stateStore: PluginManagerFileStateStore(
                fileURL: workspace.configuration.stateFileURL,
                replacer: replacer
            )
        )
        try await prepareInstalledDirectory(with: manager)
        let package = try makePackage(
            in: workspace.configuration.installedDirectoryURL,
            directoryName: "AtomicStatePlugin",
            id: "com.example.atomicstate"
        )
        _ = await manager.discover()
        _ = try await manager.enable(id: package.id)
        let originalBytes = try Data(contentsOf: workspace.configuration.stateFileURL)
        replacer.setReplacementFailure(true)

        do {
            _ = try await manager.disable(id: package.id)
            XCTFail("Expected atomic replacement to fail")
        } catch let error as PluginManagerError {
            XCTAssertEqual(error, .stateWriteFailed)
        }

        XCTAssertEqual(try Data(contentsOf: workspace.configuration.stateFileURL), originalBytes)
        let isEnabled = await manager.isEnabled(id: package.id)
        XCTAssertTrue(isEnabled)

        let prepared = try XCTUnwrap(replacer.rejectedPreparation())
        XCTAssertEqual(prepared.destination, workspace.configuration.stateFileURL)
        XCTAssertEqual(prepared.permissions, 0o600)
        XCTAssertEqual(
            prepared.temporaryURL.deletingLastPathComponent(),
            workspace.configuration.stateDirectoryURL
        )
        let preparedState = try JSONDecoder().decode(PluginManagerStateFile.self, from: prepared.data)
        XCTAssertEqual(preparedState.plugins[package.id]?.version, try SemanticVersion("1.0.0"))
        XCTAssertEqual(preparedState.plugins[package.id]?.isEnabled, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.temporaryURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: workspace.configuration.stateDirectoryURL,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent), [workspace.configuration.stateFileURL.lastPathComponent])
        XCTAssertEqual(try permissions(of: workspace.configuration.stateFileURL), 0o600)

        let restartedManager = PluginManager(configuration: workspace.configuration)
        let report = await restartedManager.discover()
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.plugins.map(\.id), [package.id])
        XCTAssertTrue(report.plugins.first?.isEnabled == true)
    }

    func testUninstallStateWriteFailureRestoresPackageAndEnabledSibling() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.remove() }
        let store = ControllableStateStore()
        let manager = PluginManager(configuration: workspace.configuration, stateStore: store)
        try await prepareInstalledDirectory(with: manager)
        let target = try makePackage(
            in: workspace.configuration.installedDirectoryURL,
            directoryName: "RollbackTarget",
            id: "com.example.rollbacktarget"
        )
        let sibling = try makePackage(
            in: workspace.configuration.installedDirectoryURL,
            directoryName: "RollbackSibling",
            id: "com.example.rollbacksibling"
        )
        _ = await manager.discover()
        _ = try await manager.enable(id: target.id)
        _ = try await manager.enable(id: sibling.id)
        let originalEntry = try Data(contentsOf: target.entryURL)
        let originalManifest = try Data(contentsOf: target.manifestURL)
        store.setSaveFailure(true)

        do {
            _ = try await manager.uninstall(id: target.id)
            XCTFail("Expected uninstall state write to fail")
        } catch let error as PluginManagerError {
            XCTAssertEqual(error, .stateWriteFailed)
        }

        XCTAssertEqual(try Data(contentsOf: target.entryURL), originalEntry)
        XCTAssertEqual(try Data(contentsOf: target.manifestURL), originalManifest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.packageURL.path))
        let records = await manager.plugins()
        XCTAssertEqual(records.map(\.id), [sibling.id, target.id])
        XCTAssertTrue(records.allSatisfy(\.isEnabled))
        XCTAssertEqual(try store.load().plugins[target.id]?.isEnabled, true)
        XCTAssertEqual(try store.load().plugins[sibling.id]?.isEnabled, true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: workspace.configuration.trashDirectoryURL,
            includingPropertiesForKeys: nil
        ).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: workspace.configuration.recoveryDirectoryURL,
            includingPropertiesForKeys: nil
        ).isEmpty)

        store.setSaveFailure(false)
        let restartedManager = PluginManager(configuration: workspace.configuration, stateStore: store)
        let restored = await restartedManager.discover()
        XCTAssertTrue(restored.failures.isEmpty)
        XCTAssertEqual(restored.plugins.map(\.id), [sibling.id, target.id])
        XCTAssertTrue(restored.plugins.allSatisfy(\.isEnabled))
    }

    func testUninstallRollbackFailureDropsRegistrationAndPreservesRecoveryPackage() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.remove() }
        let store = ControllableStateStore()
        let manager = PluginManager(configuration: workspace.configuration, stateStore: store)
        try await prepareInstalledDirectory(with: manager)
        let target = try makePackage(
            in: workspace.configuration.installedDirectoryURL,
            directoryName: "RecoveryTarget",
            id: "com.example.recoverytarget"
        )
        let sibling = try makePackage(
            in: workspace.configuration.installedDirectoryURL,
            directoryName: "RecoverySibling",
            id: "com.example.recoverysibling"
        )
        _ = await manager.discover()
        _ = try await manager.enable(id: target.id)
        _ = try await manager.enable(id: sibling.id)
        let originalEntry = try Data(contentsOf: target.entryURL)
        let originalManifest = try Data(contentsOf: target.manifestURL)
        store.setSaveFailure(true, sideEffect: {
            try FileManager.default.createDirectory(
                at: target.packageURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        })

        do {
            _ = try await manager.uninstall(id: target.id)
            XCTFail("Expected blocked rollback to fail explicitly")
        } catch let error as PluginManagerError {
            XCTAssertEqual(error, .uninstallRollbackFailed(target.id))
        }

        let targetAfterFailure = await manager.plugin(id: target.id)
        let targetSnapshot = await manager.validatedPackage(id: target.id)
        let siblingEnabled = await manager.isEnabled(id: sibling.id)
        XCTAssertNil(targetAfterFailure)
        XCTAssertNil(targetSnapshot)
        XCTAssertTrue(siblingEnabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.entryURL.path))

        let recoveryPackages = try FileManager.default.contentsOfDirectory(
            at: workspace.configuration.recoveryDirectoryURL,
            includingPropertiesForKeys: nil
        )
        let preserved = try XCTUnwrap(recoveryPackages.first)
        XCTAssertEqual(recoveryPackages.count, 1)
        XCTAssertEqual(try Data(contentsOf: preserved.appendingPathComponent("index.js")), originalEntry)
        XCTAssertEqual(try Data(contentsOf: preserved.appendingPathComponent("manifest.json")), originalManifest)

        try FileManager.default.removeItem(at: target.packageURL)
        store.setSaveFailure(false)
        let restartedManager = PluginManager(configuration: workspace.configuration, stateStore: store)
        let report = await restartedManager.discover()
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.plugins.map(\.id), [sibling.id])
        XCTAssertTrue(report.plugins.first?.isEnabled == true)
        XCTAssertEqual(try Data(contentsOf: preserved.appendingPathComponent("index.js")), originalEntry)
        XCTAssertEqual(try Data(contentsOf: preserved.appendingPathComponent("manifest.json")), originalManifest)
    }

    func testManagerCreatesPrivateDirectoriesAndStateFile() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.remove() }
        let manager = PluginManager(configuration: workspace.configuration)

        let report = await manager.discover()

        XCTAssertTrue(report.failures.isEmpty)
        for directory in [
            workspace.configuration.rootDirectoryURL,
            workspace.configuration.installedDirectoryURL,
            workspace.configuration.stateDirectoryURL,
            workspace.configuration.trashDirectoryURL,
            workspace.configuration.recoveryDirectoryURL
        ] {
            XCTAssertEqual(try permissions(of: directory), 0o700, directory.path)
        }
        XCTAssertEqual(try permissions(of: workspace.configuration.stateFileURL), 0o600)
    }

    func testInsecureManagedDirectoryIsRejectedBeforeDiscovery() async throws {
        let workspace = try makeWorkspace()
        defer { workspace.remove() }
        try FileManager.default.createDirectory(
            at: workspace.configuration.rootDirectoryURL,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(chmod(workspace.configuration.rootDirectoryURL.path, 0o777), 0)
        let manager = PluginManager(configuration: workspace.configuration)

        let report = await manager.discover()

        XCTAssertTrue(report.plugins.isEmpty)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.error, .insecureManagedDirectory("Plugins"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.configuration.stateFileURL.path))
    }

    // MARK: - Fixtures

    private struct Workspace {
        let configuration: PluginManagerConfiguration

        func remove() {
            try? FileManager.default.removeItem(at: configuration.rootDirectoryURL)
        }
    }

    private struct PackageFixture {
        let id: String
        let packageURL: URL
        let manifestURL: URL
        let entryURL: URL
    }

    private func makeWorkspace() throws -> Workspace {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginManagerTests-\(UUID().uuidString)", isDirectory: true)
        return Workspace(configuration: PluginManagerConfiguration(
            rootDirectoryURL: root,
            hostVersion: try SemanticVersion("0.6.0")
        ))
    }

    private func prepareInstalledDirectory(with manager: PluginManager) async throws {
        let report = await manager.discover()
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(report.plugins.isEmpty)
    }

    @discardableResult
    private func makePackage(
        in installedDirectory: URL,
        directoryName: String,
        id: String,
        version: String = "1.0.0",
        entrySource: String = "export default { activate() {} }"
    ) throws -> PackageFixture {
        let packageURL = installedDirectory.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        XCTAssertEqual(chmod(packageURL.path, S_IRWXU), 0)

        let manifestURL = packageURL.appendingPathComponent("manifest.json", isDirectory: false)
        try writeManifest(to: manifestURL, id: id, version: version)
        let entryURL = packageURL.appendingPathComponent("index.js", isDirectory: false)
        try Data(entrySource.utf8).write(to: entryURL)

        return PackageFixture(
            id: id,
            packageURL: packageURL,
            manifestURL: manifestURL,
            entryURL: entryURL
        )
    }

    private func writeManifest(
        to url: URL,
        id: String,
        version: String
    ) throws {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "id": id,
            "name": "Test Plugin",
            "version": version,
            "engine": "javascriptcore",
            "entry": "index.js",
            "minimumHostVersion": "0.6.0",
            "permissions": [],
            "capabilities": []
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url)
    }

    private func loadResult(
        manager: PluginManager,
        packageURL: URL
    ) async -> Result<PluginRecord, PluginManagerError> {
        do {
            return .success(try await manager.load(at: packageURL))
        } catch let error as PluginManagerError {
            return .failure(error)
        } catch {
            return .failure(.discoveryFailed)
        }
    }

    private func permissions(of url: URL) throws -> Int {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Int(status.st_mode & 0o777)
    }
}

private enum ControllableStateStoreError: Error {
    case forcedSaveFailure
}

private final class ControllableStateStore: PluginManagerStatePersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var state = PluginManagerStateFile.empty
    private var failsSave = false
    private var saveFailureSideEffect: (@Sendable () throws -> Void)?

    func load() throws -> PluginManagerStateFile {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func save(_ state: PluginManagerStateFile) throws {
        lock.lock()
        defer { lock.unlock() }
        if failsSave {
            try saveFailureSideEffect?()
            throw ControllableStateStoreError.forcedSaveFailure
        }
        self.state = state
    }

    func setSaveFailure(
        _ shouldFail: Bool,
        sideEffect: (@Sendable () throws -> Void)? = nil
    ) {
        lock.lock()
        failsSave = shouldFail
        saveFailureSideEffect = sideEffect
        lock.unlock()
    }
}

private final class ControllableStateFileReplacer: PluginManagerStateFileReplacing, @unchecked Sendable {
    struct PreparedFile {
        let temporaryURL: URL
        let destination: URL
        let permissions: Int
        let data: Data
    }

    private let lock = NSLock()
    private var failsReplacement = false
    private var preparation: PreparedFile?

    func replace(preparedFile: URL, destination: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        if failsReplacement {
            var status = stat()
            guard lstat(preparedFile.path, &status) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            preparation = PreparedFile(
                temporaryURL: preparedFile,
                destination: destination,
                permissions: Int(status.st_mode & 0o777),
                data: try Data(contentsOf: preparedFile)
            )
            throw ControllableStateStoreError.forcedSaveFailure
        }
        guard Darwin.rename(preparedFile.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func setReplacementFailure(_ shouldFail: Bool) {
        lock.lock()
        failsReplacement = shouldFail
        preparation = nil
        lock.unlock()
    }

    func rejectedPreparation() -> PreparedFile? {
        lock.lock()
        defer { lock.unlock() }
        return preparation
    }
}
