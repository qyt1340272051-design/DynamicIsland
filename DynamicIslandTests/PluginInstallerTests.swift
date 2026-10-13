import Darwin
import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginInstallerTests: XCTestCase {
    func testPreviewDoesNotRegisterPermissionsOrExecuteAndCommitRequiresExplicitEnablement() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let archive = try archive(in: f.root, version: "1.0.0", permissions: [.localStorage])
        let preview = try await f.installer.prepare(archiveURL: archive)
        XCTAssertEqual(preview.name, "Installer Test")
        XCTAssertEqual(preview.permissions, [.localStorage])
        XCTAssertFalse(preview.isUpgrade)
        XCTAssertTrue(f.runtimes.values.isEmpty)
        let before = await f.manager.plugins()
        XCTAssertTrue(before.isEmpty)
        let stagedPackage = try PluginValidator().validateExpandedPackage(at: XCTUnwrap(stageURLs(f).first),
            context: .init(hostVersion: f.configuration.hostVersion, occupiedPluginIDs: [],
                           allowedContainerURL: f.configuration.stagingDirectoryURL))
        XCTAssertThrowsError(try f.permissions.snapshot(package: stagedPackage))

        let installed = try await f.installer.commit(preview)

        XCTAssertFalse(installed.isEnabled)
        XCTAssertEqual(installed.canonicalRootURL.lastPathComponent, f.id)
        XCTAssertTrue(f.runtimes.values.isEmpty)
        let packageValue = await f.manager.validatedPackage(id: f.id)
        let package = try XCTUnwrap(packageValue)
        XCTAssertEqual(try f.permissions.state(permission: .localStorage, package: package), .requested)
        let fresh = PluginManager(configuration: f.configuration, stateStore: f.state)
        let freshReport = await fresh.discover()
        XCTAssertFalse(freshReport.plugins.first?.isEnabled == true)
        _ = try await f.manager.enable(id: f.id)
        try await marker(try XCTUnwrap(f.runtimes.values.last))
        XCTAssertEqual(f.activities.current?.presentation.title, "Version 1.0.0")
        await assertInstallerError(.staleReview) { try await f.installer.commit(preview) }
        await assertInstallerError(.staleReview) { try await f.installer.cancel(preview) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.canonicalRootURL.path))
    }

    func testCancelOnlyConsumesOwnReviewAndCleansItsStage() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let preview = try await f.installer.prepare(archiveURL: archive(in: f.root))
        let other = PluginInstaller(manager: f.manager, configuration: f.configuration)
        await assertInstallerError(.staleReview) { try await other.cancel(preview) }
        XCTAssertEqual(try stageURLs(f).count, 1)
        await assertInstallerError(.busy) { try await f.installer.prepare(archiveURL: archive(in: f.root)) }
        try await f.installer.cancel(preview)
        XCTAssertTrue(try stageURLs(f).isEmpty)
        await assertInstallerError(.staleReview) { try await f.installer.commit(preview) }
        XCTAssertTrue(f.runtimes.values.isEmpty)
    }

    func testCancelCleanupFailureRetainsReviewForCleanupRetryOnly() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let preview = try await f.installer.prepare(archiveURL: archive(in: f.root))
        let stage = try XCTUnwrap(stageURLs(f).first)
        XCTAssertEqual(chmod(stage.path, 0o500), 0)
        await assertInstallerError(.cleanupFailed) { try await f.installer.cancel(preview) }
        await assertInstallerError(.staleReview) { try await f.installer.commit(preview) }
        XCTAssertEqual(chmod(stage.path, 0o700), 0)
        try await f.installer.cancel(preview)
        XCTAssertTrue(try stageURLs(f).isEmpty)
    }

    func testMutationOfSameSizedEntryAfterPreviewFailsClosedAndConsumesReview() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let preview = try await f.installer.prepare(archiveURL: archive(in: f.root))
        let stage = try XCTUnwrap(stageURLs(f).first)
        let entry = stage.appendingPathComponent("main.js")
        let before = try Data(contentsOf: entry)
        var changed = before
        changed[changed.startIndex] = changed[changed.startIndex] == 102 ? 103 : 102
        try changed.write(to: entry)
        await assertInstallerError(.staleReview) { try await f.installer.commit(preview) }
        await assertInstallerError(.staleReview) { try await f.installer.commit(preview) }
        let installed = await f.manager.plugins()
        XCTAssertTrue(installed.isEmpty)
        XCTAssertTrue(f.runtimes.values.isEmpty)
    }

    func testSameSizedResourceMutationIsCaughtByWholeTreeFingerprint() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let preview = try await f.installer.prepare(archiveURL: archive(in: f.root, resource: Data("AAAA".utf8)))
        let stage = try XCTUnwrap(stageURLs(f).first)
        try Data("BBBB".utf8).write(to: stage.appendingPathComponent("resource.txt"))
        await assertInstallerError(.staleReview) { try await f.installer.commit(preview) }
        XCTAssertTrue(f.runtimes.values.isEmpty)
        let installed = await f.manager.plugins()
        XCTAssertTrue(installed.isEmpty)
    }

    func testSameVersionResourceCommitInvalidatesEarlierInstalledGenerationReview() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        try await installOld(f)
        let root = f.configuration.installedDirectoryURL.appendingPathComponent(f.id)
        try Data("AAAA".utf8).write(to: root.appendingPathComponent("resource.txt"))
        _ = try await f.manager.reload(id: f.id)
        let oldDTO = await f.manager.validatedPackage(id: f.id)
        let first = try await f.installer.prepare(archiveURL: archive(in: f.root, resource: Data("BBBB".utf8)))
        let other = PluginInstaller(manager: f.manager, configuration: f.configuration)
        let second = try await other.prepare(archiveURL: archive(in: f.root, resource: Data("CCCC".utf8)))
        _ = try await other.commit(second)
        let sameDTO = await f.manager.validatedPackage(id: f.id)
        XCTAssertEqual(sameDTO, oldDTO, "Resource changes are absent from the lightweight package DTO.")

        await assertInstallerError(.staleReview) { try await f.installer.commit(first) }

        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("resource.txt")), Data("CCCC".utf8))
    }

    func testFailedCommitRetainsOnlyOwnedCleanupReservationAndBlocksNewPrepareUntilRetry() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        let review = try await f.installer.prepare(archiveURL: archive(in: f.root))
        let stage = try XCTUnwrap(stageURLs(f).first)
        XCTAssertEqual(chmod(stage.path, 0o500), 0)
        f.state.failNextSave()
        await assertInstallerError(.cleanupFailed) { try await f.installer.commit(review) }
        let pending = await f.installer.hasPendingCleanup()
        XCTAssertTrue(pending)
        await assertInstallerError(.busy) { try await f.installer.prepare(archiveURL: archive(in: f.root)) }
        await assertInstallerError(.staleReview) { try await f.installer.cancel(review) }
        XCTAssertEqual(chmod(stage.path, 0o700), 0)
        try await f.installer.retryCleanup()
        let cleaned = await f.installer.hasPendingCleanup()
        XCTAssertFalse(cleaned)
        let next = try await f.installer.prepare(archiveURL: archive(in: f.root))
        try await f.installer.cancel(next)
        XCTAssertTrue(try stageURLs(f).isEmpty)
    }

    func testStageCountAndAggregateQuotaBoundLeftoversAcrossInstallerRestarts() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        for _ in 0..<4 {
            try FileManager.default.createDirectory(at: f.configuration.stagingDirectoryURL.appendingPathComponent(UUID().uuidString),
                withIntermediateDirectories: false, attributes: [.posixPermissions: NSNumber(value: 0o700)])
        }
        await assertInstallerError(.stagingFailed) { try await f.installer.prepare(archiveURL: archive(in: f.root)) }
        XCTAssertEqual(try stageURLs(f).count, 4)
        for directory in try stageURLs(f) { try FileManager.default.removeItem(at: directory) }
        for _ in 0..<3 {
            let root = f.configuration.stagingDirectoryURL.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let file = root.appendingPathComponent("logical-bytes")
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 48 * 1_024 * 1_024)
            try handle.close()
        }
        let restarted = PluginInstaller(manager: f.manager, configuration: f.configuration)
        await assertInstallerError(.stagingFailed) { try await restarted.prepare(archiveURL: archive(in: f.root)) }
        XCTAssertEqual(try stageURLs(f).count, 3)
    }

    func testInstalledReplacementBetweenPreviewAndCommitCannotBeOverwritten() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        try await installOld(f)
        let review = try await f.installer.prepare(archiveURL: archive(in: f.root, version: "2.0.0"))
        let old = f.configuration.installedDirectoryURL.appendingPathComponent(f.id)
        try Data((source("1.0.0") + "\nconst replacement = true;").utf8).write(to: old.appendingPathComponent("main.js"))
        _ = try await f.manager.reload(id: f.id)
        let current = await f.manager.validatedPackage(id: f.id)
        await assertInstallerError(.staleReview) { try await f.installer.commit(review) }
        let after = await f.manager.validatedPackage(id: f.id)
        XCTAssertEqual(after, current)
    }

    func testUpgradeStopsOldRuntimeCommitsDisabledAndRequestsChangedPermissions() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        try await installOld(f, enabled: true)
        let oldPackageValue = await f.manager.validatedPackage(id: f.id)
        let oldPackage = try XCTUnwrap(oldPackageValue)
        let oldReview = try f.permissions.snapshot(package: oldPackage).review
        try f.permissions.applyHostDecision(decision: .granted, review: oldReview, permission: .localStorage)
        let lease = try f.permissions.require(permission: .localStorage, package: oldPackage)
        let oldContext = try XCTUnwrap(f.runtimes.contexts.last)
        let preview = try await f.installer.prepare(archiveURL: archive(in: f.root, version: "2.0.0", permissions: [.network, .localStorage]))
        XCTAssertTrue(preview.isUpgrade)
        XCTAssertFalse(preview.isDowngrade)
        XCTAssertEqual(preview.previousVersion, try SemanticVersion("1.0.0"))

        let installed = try await f.installer.commit(preview)

        XCTAssertFalse(installed.isEnabled)
        XCTAssertNil(f.activities.current)
        XCTAssertEqual(f.runtimes.values.count, 1)
        XCTAssertThrowsError(try oldContext.perform {})
        XCTAssertThrowsError(try lease.perform {})
        let nextValue = await f.manager.validatedPackage(id: f.id)
        let next = try XCTUnwrap(nextValue)
        XCTAssertEqual(try f.permissions.snapshot(package: next).states, [.network: .requested, .localStorage: .requested])
        _ = try await f.manager.enable(id: f.id)
        try await marker(try XCTUnwrap(f.runtimes.values.last))
        XCTAssertEqual(f.activities.current?.presentation.title, "Version 2.0.0")
    }

    func testDowngradeIsExplicitPreviewAndAlsoCommitsDisabled() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        try await installOld(f, version: "2.0.0")
        let preview = try await f.installer.prepare(archiveURL: archive(in: f.root, version: "1.0.0"))
        XCTAssertTrue(preview.isDowngrade)
        let result = try await f.installer.commit(preview)
        XCTAssertFalse(result.isEnabled)
        XCTAssertEqual(result.manifest.version, try SemanticVersion("1.0.0"))
    }

    func testRecoveryBudgetIncludesOldPackageBeforeRuntimeStop() async throws {
        let limits = PluginPackageLimits(maxTotalFileBytes: 1_024)
        let f = try await fixture(limits: limits)
        defer { f.cleanup() }
        try await installOld(f, enabled: true)
        let oldValue = await f.manager.validatedPackage(id: f.id)
        let old = try XCTUnwrap(oldValue)
        let oldContext = try XCTUnwrap(f.runtimes.contexts.last)
        let activity = f.activities.currentSnapshot
        let prior = f.configuration.recoveryDirectoryURL.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: prior, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        // Existing recovery fits on its own. Adding the old package exceeds
        // the four-package budget by exactly one byte.
        let priorBytes = limits.maxTotalFileBytes * 4 - old.totalFileBytes + 1
        let saved = Data(repeating: 0, count: Int(priorBytes))
        try saved.write(to: prior.appendingPathComponent("retained"))
        let review = try await f.installer.prepare(archiveURL: archive(in: f.root, version: "2.0.0"))

        await assertInstallerError(.stagingFailed) { try await f.installer.commit(review) }

        XCTAssertNoThrow(try oldContext.perform {})
        XCTAssertEqual(f.lifecycle.snapshot(id: f.id)?.state, .running)
        XCTAssertEqual(f.runtimes.values.count, 1)
        XCTAssertEqual(f.activities.currentSnapshot, activity)
        let current = await f.manager.validatedPackage(id: f.id)
        XCTAssertEqual(current, old)
        XCTAssertEqual(try Data(contentsOf: old.canonicalRootURL.appendingPathComponent("main.js")), old.entrySource)
        XCTAssertEqual(try Data(contentsOf: prior.appendingPathComponent("retained")), saved)
        XCTAssertTrue(try PluginInstallationMarkerStore(directoryURL: f.configuration.stateDirectoryURL).readAll().isEmpty)
        XCTAssertThrowsError(try PluginInstallationSpace.check(f.configuration.recoveryDirectoryURL,
            maximumRoots: 16, limits: limits, additionalBytes: UInt64.max)) {
            XCTAssertEqual($0 as? PluginManagerError, .installRecoveryRequired)
        }
    }

    func testFailedStateSaveRestoresOldBytesRuntimeAndPermissionScopeWithoutRevivingRevokedLease() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        try await installOld(f, enabled: true)
        let oldValue = await f.manager.validatedPackage(id: f.id)
        let old = try XCTUnwrap(oldValue)
        let permissionReview = try f.permissions.snapshot(package: old).review
        try f.permissions.applyHostDecision(decision: .granted, review: permissionReview, permission: .localStorage)
        let revoked = try f.permissions.require(permission: .localStorage, package: old)
        try f.permissions.applyHostDecision(decision: .revoked, review: permissionReview, permission: .localStorage)
        let oldContext = try XCTUnwrap(f.runtimes.contexts.last)
        let preview = try await f.installer.prepare(archiveURL: archive(in: f.root, version: "2.0.0"))
        f.state.failNextSave()
        await assertInstallerError(.installFailed) { try await f.installer.commit(preview) }
        let restoredValue = await f.manager.validatedPackage(id: f.id)
        XCTAssertEqual(restoredValue, old)
        XCTAssertEqual(try Data(contentsOf: old.canonicalRootURL.appendingPathComponent("main.js")), old.entrySource)
        XCTAssertEqual(try f.permissions.snapshot(package: old).review, permissionReview)
        XCTAssertEqual(try f.permissions.state(permission: .localStorage, package: old), .revoked)
        XCTAssertThrowsError(try revoked.perform {})
        XCTAssertThrowsError(try oldContext.perform {})
        XCTAssertEqual(f.runtimes.values.count, 2)
        try await marker(try XCTUnwrap(f.runtimes.values.last))
        XCTAssertEqual(f.activities.current?.presentation.title, "Version 1.0.0")
        XCTAssertTrue(try PluginInstallationMarkerStore(directoryURL: f.configuration.stateDirectoryURL).readAll().isEmpty)
    }

    func testMoveFailureRestoresOldRuntimeAndNeverRegistersNewPermissionScope() async throws {
        let mover = InstallerTestMover(failingMoves: [2])
        let f = try await fixture(mover: mover)
        defer { f.cleanup() }
        try await installOld(f, enabled: true)
        let oldValue = await f.manager.validatedPackage(id: f.id)
        let old = try XCTUnwrap(oldValue)
        let oldReview = try f.permissions.snapshot(package: old).review
        let review = try await f.installer.prepare(archiveURL: archive(in: f.root, version: "2.0.0", permissions: [.network]))
        await assertInstallerError(.installFailed) { try await f.installer.commit(review) }
        let after = await f.manager.validatedPackage(id: f.id)
        XCTAssertEqual(after, old)
        XCTAssertEqual(try f.permissions.snapshot(package: old).review, oldReview)
        try await marker(try XCTUnwrap(f.runtimes.values.last))
        XCTAssertEqual(f.runtimes.values.count, 2)
    }

    func testRollbackFailureRetainsRecoveryAndDoesNotRestartOldOrNewCode() async throws {
        let mover = InstallerTestMover(failingMoves: [4])
        let f = try await fixture(mover: mover)
        defer { f.cleanup() }
        try await installOld(f, enabled: true)
        let review = try await f.installer.prepare(archiveURL: archive(in: f.root, version: "2.0.0"))
        f.state.failNextSave()
        await assertInstallerError(.rollbackFailed) { try await f.installer.commit(review) }
        let registered = await f.manager.plugins()
        XCTAssertTrue(registered.isEmpty)
        XCTAssertFalse(f.lifecycle.allowsExecution(id: f.id))
        XCTAssertNil(f.activities.current)
        XCTAssertEqual(f.runtimes.values.count, 1)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.configuration.recoveryDirectoryURL.path).isEmpty)
        XCTAssertEqual(try PluginInstallationMarkerStore(directoryURL: f.configuration.stateDirectoryURL).readAll().map(\.pluginID), [f.id])
        let fresh = PluginManager(configuration: f.configuration, stateStore: f.state)
        let report = await fresh.discover()
        XCTAssertTrue(report.plugins.isEmpty)
        XCTAssertTrue(report.failures.contains { $0.error == .installRecoveryRequired })
    }

    func testCommittedCleanupFailureKeepsInstalledDisabledAndNextDiscoveryCanResolveValidMarker() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        try await installOld(f)
        let review = try await f.installer.prepare(archiveURL: archive(in: f.root, version: "2.0.0"))
        let duplicate = f.root.appendingPathComponent("marker-hardlink")
        let stateDirectory = f.configuration.stateDirectoryURL
        f.state.onNextSave {
            let marker = try PluginInstallationMarkerStore(directoryURL: stateDirectory).readAll().first!
            try FileManager.default.linkItem(at: stateDirectory.appendingPathComponent(marker.filename), to: duplicate)
        }
        await assertInstallerError(.cleanupFailed) { try await f.installer.commit(review) }
        let result = await f.manager.plugin(id: f.id)
        XCTAssertEqual(result?.manifest.version, try SemanticVersion("2.0.0"))
        XCTAssertFalse(result?.isEnabled == true)
        XCTAssertTrue(f.runtimes.values.isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.configuration.recoveryDirectoryURL.path).isEmpty)
        let fresh = PluginManager(configuration: f.configuration, stateStore: f.state)
        let corrupt = await fresh.discover()
        XCTAssertTrue(corrupt.failures.contains { $0.error == .stateReadFailed })
        XCTAssertFalse(corrupt.plugins.first?.isEnabled == true)
        try FileManager.default.removeItem(at: duplicate)
        let recovered = await fresh.discover()
        XCTAssertTrue(recovered.failures.contains { $0.error == .installRecoveryRequired })
        XCTAssertFalse(recovered.plugins.first?.isEnabled == true)
        XCTAssertTrue(try PluginInstallationMarkerStore(directoryURL: f.configuration.stateDirectoryURL).readAll().isEmpty)
    }

    func testInterruptedSameVersionMarkerForcesDisabledBeforeClearingMarker() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        try await installOld(f, enabled: true)
        _ = try PluginInstallationMarkerStore(directoryURL: f.configuration.stateDirectoryURL).create(pluginID: f.id)
        f.lifecycle.shutdown()
        let fresh = PluginManager(configuration: f.configuration, stateStore: f.state)
        let report = await fresh.discover()
        XCTAssertFalse(report.plugins.first?.isEnabled == true)
        XCTAssertTrue(report.failures.contains { $0.error == .installRecoveryRequired })
        XCTAssertTrue(try PluginInstallationMarkerStore(directoryURL: f.configuration.stateDirectoryURL).readAll().isEmpty)
        let second = await fresh.discover()
        XCTAssertFalse(second.plugins.first?.isEnabled == true)
    }

    func testCorruptMarkerDisablesEveryDiscoveredPackageAndIsNeverOverwritten() async throws {
        let f = try await fixture()
        defer { f.cleanup() }
        try await installOld(f, enabled: true)
        let marker = try PluginInstallationMarkerStore(directoryURL: f.configuration.stateDirectoryURL).create(pluginID: f.id)
        let markerURL = f.configuration.stateDirectoryURL.appendingPathComponent(marker.filename)
        let corrupt = Data("{\"schemaVersion\":1,\"token\":\"\(marker.token.uuidString)\",\"pluginID\":\"\(f.id)\",\"unknown\":true}".utf8)
        try corrupt.write(to: markerURL)
        f.lifecycle.shutdown()
        let fresh = PluginManager(configuration: f.configuration, stateStore: f.state)
        let report = await fresh.discover()
        XCTAssertFalse(report.plugins.first?.isEnabled == true)
        XCTAssertTrue(report.failures.contains { $0.error == .stateReadFailed })
        XCTAssertEqual(try Data(contentsOf: markerURL), corrupt)
        await assertManagerError(.stateReadFailed) { try await fresh.enable(id: f.id) }
        await assertInstallerError(.stagingFailed) { try await f.installer.prepare(archiveURL: archive(in: f.root)) }
    }

    func testOversizedInjectedLimitsCannotExpandFingerprintResourceCeilings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InstallerLimits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let large = root.appendingPathComponent("resource")
        XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 8 * 1_024 * 1_024 + 1)
        try handle.close()
        XCTAssertThrowsError(try PluginInstallationFingerprint.read(root, limits: .init(maxSingleFileBytes: 100_000_000,
                                                                                       maxTotalFileBytes: 100_000_000))) {
            XCTAssertEqual($0 as? PluginInstallerError, .quotaExceeded)
        }
    }

    private func fixture(mover: (any PluginManagerInstallationMoving)? = nil,
                         limits: PluginPackageLimits = .init()) async throws -> InstallerTestFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Installer-\(UUID().uuidString)")
        let configuration = PluginManagerConfiguration(rootDirectoryURL: root, hostVersion: try SemanticVersion("0.6.0"), limits: limits)
        let permissions = PermissionManager()
        let state = InstallerTestStateStore()
        let activities = ActivityManager(configuration: .immediate)
        let runtimeList = InstallerTestRuntimes()
        let bridge = PluginJSBridge(permissions: permissions)
        let lifecycle = PluginLifecycleBridge(activityManager: activities, actionRouter: ActionRouter(manager: activities),
            permissions: permissions, runtimeFactory: { package in
                let runtime = PluginRuntime(package: package, bridge: bridge)
                runtimeList.values.append(runtime)
                return InstallerTestRuntime(runtime: runtime, collect: { runtimeList.contexts.append($0) })
            })
        let manager = PluginManager(configuration: configuration, stateStore: state, lifecycleHandler: lifecycle,
            installationMover: mover ?? PluginManagerExclusiveInstallationMover())
        let initial = await manager.discover()
        XCTAssertTrue(initial.failures.isEmpty)
        return .init(root: root, configuration: configuration, manager: manager,
            installer: PluginInstaller(manager: manager, configuration: configuration), lifecycle: lifecycle,
            permissions: permissions, state: state, runtimes: runtimeList, activities: activities)
    }

    private func installOld(_ f: InstallerTestFixture, version: String = "1.0.0", enabled: Bool = false) async throws {
        let directory = f.configuration.installedDirectoryURL.appendingPathComponent(f.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try manifest(version: version).encodeJSON().write(to: directory.appendingPathComponent("manifest.json"))
        try Data(source(version).utf8).write(to: directory.appendingPathComponent("main.js"))
        _ = try await f.manager.load(at: directory)
        if enabled {
            _ = try await f.manager.enable(id: f.id)
            try await marker(try XCTUnwrap(f.runtimes.values.last))
        }
    }
    private func manifest(version: String, permissions: [PluginPermission] = [.localStorage]) throws -> PluginManifest {
        try PluginManifest(id: "com.example.installer", name: "Installer Test", version: SemanticVersion(version),
            engine: .javaScriptCore, entry: "main.js", minimumHostVersion: SemanticVersion("0.6.0"),
            permissions: permissions, capabilities: [.publishActivity], developer: "Installer Developer")
    }
    private func source(_ version: String) -> String {
        "function onStart(){island.activity.publish({id:'installer',presentation:{title:'Version \(version)'}}).then(()=>{globalThis.published=true;});}"
    }
    private func archive(in root: URL, version: String = "1.0.0", permissions: [PluginPermission] = [.localStorage],
                         resource: Data? = nil) throws -> URL {
        var files = [("manifest.json", try manifest(version: version, permissions: permissions).encodeJSON()),
                     ("main.js", Data(source(version).utf8))]
        if let resource { files.append(("resource.txt", resource)) }
        let url = root.appendingPathComponent("\(UUID().uuidString).dip")
        try installerZIP(files).write(to: url)
        return url
    }
    private func stageURLs(_ f: InstallerTestFixture) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: f.configuration.stagingDirectoryURL, includingPropertiesForKeys: nil)
    }
    private func marker(_ runtime: PluginRuntime) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await runtime.evaluateForTesting("globalThis.published === true") != .boolean(true) {
            guard ContinuousClock.now < deadline else { throw InstallerTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func assertInstallerError<T>(_ expected: PluginInstallerError,
                                         operation: () async throws -> T) async {
        do { _ = try await operation(); XCTFail("Expected \(expected).") }
        catch { XCTAssertEqual(error as? PluginInstallerError, expected) }
    }
    private func assertManagerError<T>(_ expected: PluginManagerError,
                                       operation: () async throws -> T) async {
        do { _ = try await operation(); XCTFail("Expected \(expected).") }
        catch { XCTAssertEqual(error as? PluginManagerError, expected) }
    }
}

@MainActor
private struct InstallerTestFixture {
    let id = "com.example.installer"
    let root: URL
    let configuration: PluginManagerConfiguration
    let manager: PluginManager
    let installer: PluginInstaller
    let lifecycle: PluginLifecycleBridge
    let permissions: PermissionManager
    let state: InstallerTestStateStore
    let runtimes: InstallerTestRuntimes
    let activities: ActivityManager
    func cleanup() { lifecycle.shutdown(); try? FileManager.default.removeItem(at: root) }
}
@MainActor private final class InstallerTestRuntimes {
    var values: [PluginRuntime] = []
    var contexts: [PluginExecutionContext] = []
}
@MainActor private final class InstallerTestRuntime: PluginLifecycleRuntime {
    let runtime: PluginRuntime
    let collect: (PluginExecutionContext) -> Void
    init(runtime: PluginRuntime, collect: @escaping (PluginExecutionContext) -> Void) { self.runtime = runtime; self.collect = collect }
    func onStart(context: PluginExecutionContext) throws { collect(context); try runtime.onStart(context: context) }
    func onStop(reason: PluginStopReason) throws { try runtime.onStop(reason: reason) }
    func teardown() { runtime.teardown() }
}
private nonisolated final class InstallerTestMover: PluginManagerInstallationMoving, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let failingMoves: Set<Int>
    init(failingMoves: Set<Int>) { self.failingMoves = failingMoves }
    func move(source: URL, destination: URL) throws {
        let number = lock.withLock { count += 1; return count }
        if failingMoves.contains(number) { throw PluginManagerError.installFailed }
        try PluginManagerExclusiveInstallationMover().move(source: source, destination: destination)
    }
}
private nonisolated final class InstallerTestStateStore: PluginManagerStatePersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var state = PluginManagerStateFile.empty
    private var fail = false
    private var afterSave: (@Sendable () throws -> Void)?
    func load() throws -> PluginManagerStateFile { lock.withLock { state } }
    func save(_ next: PluginManagerStateFile) throws {
        let callback: (@Sendable () throws -> Void)? = try lock.withLock {
            if fail { fail = false; throw PluginManagerError.stateWriteFailed }
            state = next
            let callback = afterSave; afterSave = nil
            return callback
        }
        // This test hook mutates the marker after a successful state commit.
        // Any hook failure is a test setup failure, not a postcommit save error.
        if let callback { try! callback() }
    }
    func failNextSave() { lock.withLock { fail = true } }
    func onNextSave(_ callback: @escaping @Sendable () throws -> Void) { lock.withLock { afterSave = callback } }
}
private nonisolated enum InstallerTestError: Error { case timedOut }

/// Minimal stored ZIP fixtures avoid subprocesses in the sandboxed Test Host.
private nonisolated func installerZIP(_ files: [(String, Data)]) -> Data {
    var data = Data(), central = Data()
    func crc(_ bytes: Data) -> UInt32 {
        var value = UInt32.max
        for byte in bytes {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0xedb88320 }
        }
        return value ^ UInt32.max
    }
    for (name, content) in files {
        let name = Data(name.utf8), offset = UInt32(data.count), checksum = crc(content), size = UInt32(content.count)
        data.u32(0x04034b50); data.u16(20); data.u16(0x800); data.u16(0); data.u16(0); data.u16(0)
        data.u32(checksum); data.u32(size); data.u32(size); data.u16(UInt16(name.count)); data.u16(0)
        data.append(name); data.append(content)
        central.u32(0x02014b50); central.u16(0x0314); central.u16(20); central.u16(0x800); central.u16(0)
        central.u16(0); central.u16(0); central.u32(checksum); central.u32(size); central.u32(size)
        central.u16(UInt16(name.count)); central.u16(0); central.u16(0); central.u16(0); central.u16(0)
        central.u32(UInt32(0o100600) << 16); central.u32(offset); central.append(name)
    }
    let centralOffset = UInt32(data.count)
    data.append(central)
    data.u32(0x06054b50); data.u16(0); data.u16(0); data.u16(UInt16(files.count)); data.u16(UInt16(files.count))
    data.u32(UInt32(central.count)); data.u32(centralOffset); data.u16(0)
    return data
}
private extension Data {
    mutating func u16(_ value: UInt16) { append(contentsOf: [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]) }
    mutating func u32(_ value: UInt32) { u16(UInt16(truncatingIfNeeded: value)); u16(UInt16(truncatingIfNeeded: value >> 16)) }
}
