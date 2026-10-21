import Foundation
import XCTest
import zlib
@testable import DynamicIsland

@MainActor
final class PluginInstallerUIModelTests: XCTestCase {
    func testPreviewBalancesSourceLeaseAndDoesNotInstallExecuteOrGrant() async throws {
        let fixture = try await InstallerUIFixture.make()
        defer { fixture.cleanup() }
        let access = InstallerSourceAccessWitness()
        let model = PluginInstallerModel(installer: fixture.installer, archiveAccess: access)
        let archive = try fixture.archive(version: "1.0.0", permissions: [.readClipboard, .writeClipboard])

        let prepared = await model.importArchive(archive)
        XCTAssertTrue(prepared)

        XCTAssertEqual(model.phase, .reviewing)
        XCTAssertEqual(model.review?.name, "Installer Fixture")
        XCTAssertEqual(model.review?.developer, "Fixture Developer")
        XCTAssertFalse(model.review?.isUpgrade == true)
        XCTAssertEqual(model.review?.permissions, [.readClipboard, .writeClipboard])
        XCTAssertEqual(access.started, [archive])
        XCTAssertEqual(access.stopped, [archive])
        let listed = await fixture.manager.plugins()
        XCTAssertTrue(listed.isEmpty)
        XCTAssertEqual(fixture.starts.value, 0)
        XCTAssertEqual(try fixture.stagedCount(), 1)
        let cancelled = await model.cancel()
        XCTAssertTrue(cancelled)
        XCTAssertNil(model.review)
        XCTAssertEqual(try fixture.stagedCount(), 0)
    }

    func testConfirmInstallsDisabledAndReturnsToExtensionsCallback() async throws {
        let fixture = try await InstallerUIFixture.make()
        defer { fixture.cleanup() }
        let access = InstallerSourceAccessWitness()
        let witness = InstallerInstalledWitness()
        let model = PluginInstallerModel(installer: fixture.installer, archiveAccess: access, onInstalled: { record in
            witness.ids.append(record.id)
            XCTAssertEqual(access.started.count, access.stopped.count)
        })
        let archive = try fixture.archive(version: "1.0.0", permissions: [.readClipboard, .writeClipboard])
        _ = await model.importArchive(archive)

        await model.install()

        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.review)
        XCTAssertEqual(model.installedID, fixture.id)
        XCTAssertEqual(witness.ids, [fixture.id])
        let listed = await fixture.manager.plugins()
        let plugin = try XCTUnwrap(listed.first)
        XCTAssertFalse(plugin.isEnabled)
        let validated = await fixture.manager.validatedPackage(id: fixture.id)
        let package = try XCTUnwrap(validated)
        let permissions = try fixture.permissions.snapshot(package: package)
        XCTAssertTrue(permissions.states.values.allSatisfy { $0 == .requested })
        XCTAssertEqual(fixture.starts.value, 0)
        XCTAssertEqual(try fixture.stagedCount(), 0)
    }

    func testSecondArchiveIsRejectedWithoutReplacingPendingReviewOrOpeningAnotherLease() async throws {
        let fixture = try await InstallerUIFixture.make()
        defer { fixture.cleanup() }
        let access = InstallerSourceAccessWitness()
        let model = PluginInstallerModel(installer: fixture.installer, archiveAccess: access)
        let first = try fixture.archive(version: "1.0.0")
        let second = try fixture.archive(version: "2.0.0")
        _ = await model.importArchive(first)

        let importedSecond = await model.importArchive(second)
        XCTAssertFalse(importedSecond)

        XCTAssertEqual(model.review?.version.description, "1.0.0")
        XCTAssertEqual(model.errorCode, "busy")
        XCTAssertEqual(access.started, [first])
        XCTAssertEqual(try fixture.stagedCount(), 1)
        _ = await model.cancel()
    }

    func testAlreadyAccessibleArchiveDoesNotStopAnUnopenedScope() async throws {
        let fixture = try await InstallerUIFixture.make()
        defer { fixture.cleanup() }
        let access = InstallerSourceAccessWitness(grantsScope: false)
        let model = PluginInstallerModel(installer: fixture.installer, archiveAccess: access)
        _ = await model.importArchive(try fixture.archive(version: "1.0.0"))
        XCTAssertEqual(access.started.count, 1)
        XCTAssertTrue(access.stopped.isEmpty)
        _ = await model.cancel()
    }

    func testInvalidAndCorruptArchivesUseFixedErrorsWithoutSourcePaths() async throws {
        let fixture = try await InstallerUIFixture.make()
        defer { fixture.cleanup() }
        let access = InstallerSourceAccessWitness()
        let model = PluginInstallerModel(installer: fixture.installer, archiveAccess: access)
        let invalid = fixture.configuration.rootDirectoryURL.appendingPathComponent("SECRET-SOURCE.txt")
        let importedInvalid = await model.importArchive(invalid)
        XCTAssertFalse(importedInvalid)
        XCTAssertEqual(model.errorCode, "invalidArguments")
        XCTAssertTrue(access.started.isEmpty)
        let corrupt = fixture.configuration.rootDirectoryURL.appendingPathComponent("SECRET-SOURCE.dip")
        try Data("SECRET-PAYLOAD".utf8).write(to: corrupt)
        let importedCorrupt = await model.importArchive(corrupt)
        XCTAssertFalse(importedCorrupt)
        XCTAssertNotNil(model.errorCode)
        XCTAssertFalse(model.errorMessage?.contains("SECRET") == true)
        XCTAssertFalse(model.errorMessage?.contains(fixture.configuration.rootDirectoryURL.path) == true)
        XCTAssertEqual(access.started, access.stopped)
        XCTAssertEqual(try fixture.stagedCount(), 0)
    }

    func testTerminationDuringPrepareWaitsAndCleansTheNewReviewAndSourceLease() async throws {
        let fixture = try await InstallerUIFixture.make()
        defer { fixture.cleanup() }
        let access = InstallerSourceAccessWitness()
        let gated = InstallerPreparationGate(installer: fixture.installer)
        let model = PluginInstallerModel(installer: gated, archiveAccess: access)
        let archive = try fixture.archive(version: "1.0.0")
        let importTask = Task { await model.importArchive(archive) }
        try await InstallerUIFixture.wait { model.phase == .preparing }
        let shutdownTask = Task { await model.shutdown() }
        try await InstallerUIFixture.wait { model.isTerminating }
        await gated.release()
        let imported = await importTask.value
        XCTAssertFalse(imported)
        await shutdownTask.value
        XCTAssertNil(model.review)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(access.started, access.stopped)
        XCTAssertEqual(try fixture.stagedCount(), 0)
        let listed = await fixture.manager.plugins()
        XCTAssertTrue(listed.isEmpty)
    }

    func testStartupQueueIsBoundedAndOffersOnlyOneReviewUntilItIsCancelled() async throws {
        let fixture = try await InstallerUIFixture.make()
        defer { fixture.cleanup() }
        let model = PluginInstallerModel(installer: fixture.installer)
        let presentation = InstallerPresentationWitness()
        let coordinator = PluginImportCoordinator(onPresent: { presentation.count += 1 })
        let archive = try fixture.archive(version: "1.0.0")
        coordinator.enqueue(Array(repeating: archive, count: 8))
        XCTAssertEqual(coordinator.pendingCount, 4)
        coordinator.configure(model: model)
        try await InstallerUIFixture.wait { model.review != nil && coordinator.pendingCount == 0 }
        XCTAssertEqual(model.review?.version.description, "1.0.0")
        XCTAssertEqual(model.errorCode, "busy")
        XCTAssertEqual(try fixture.stagedCount(), 1)
        XCTAssertGreaterThan(presentation.count, 0)
        await coordinator.shutdown()
        XCTAssertNil(model.review)
        XCTAssertEqual(try fixture.stagedCount(), 0)
        coordinator.enqueue([archive])
        XCTAssertEqual(coordinator.pendingCount, 0)
    }

    func testReplacementPreviewExplicitlyIdentifiesDowngradeAndNewPermissions() async throws {
        let fixture = try await InstallerUIFixture.make()
        defer { fixture.cleanup() }
        let model = PluginInstallerModel(installer: fixture.installer)
        _ = await model.importArchive(try fixture.archive(version: "2.0.0", permissions: [.localStorage]))
        await model.install()
        _ = await model.importArchive(try fixture.archive(version: "1.0.0", permissions: [.localStorage, .readClipboard]))
        XCTAssertTrue(model.review?.isUpgrade == true)
        XCTAssertTrue(model.review?.isDowngrade == true)
        XCTAssertEqual(model.review?.previousVersion?.description, "2.0.0")
        XCTAssertTrue(model.review?.permissions.contains(.readClipboard) == true)
        await model.install()
        let listed = await fixture.manager.plugins()
        let record = try XCTUnwrap(listed.first)
        XCTAssertEqual(record.manifest.version.description, "1.0.0")
        XCTAssertFalse(record.isEnabled)
        let validated = await fixture.manager.validatedPackage(id: fixture.id)
        let package = try XCTUnwrap(validated)
        XCTAssertTrue(try fixture.permissions.snapshot(package: package).states.values.allSatisfy { $0 == .requested })
    }
    func testCommitFailureConsumesReviewAndAllowsASeparateImport() async throws {
        let fixture = try await InstallerUIFixture.make()
        defer { fixture.cleanup() }
        let handler = InstallerFailureHandler(installer: fixture.installer, mode: .commitFailed)
        let model = PluginInstallerModel(installer: handler)
        let archive = try fixture.archive(version: "1.0.0")
        _ = await model.importArchive(archive)
        await model.install()
        XCTAssertNil(model.review)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.errorCode, "installFailed")
        XCTAssertFalse(model.hasPendingImport)
        let importedAgain = await model.importArchive(archive)
        XCTAssertTrue(importedAgain)
        _ = await model.cancel()
    }

    func testCommittedCleanupFailureKeepsFixedWarningAndRefreshesManagement() async throws {
        let fixture = try await InstallerUIFixture.make()
        defer { fixture.cleanup() }
        let handler = InstallerFailureHandler(installer: fixture.installer, mode: .committedCleanupFailed)
        let witness = InstallerFailureWitness()
        let model = PluginInstallerModel(installer: handler, onInstallFailure: { review, code in
            witness.ids.append(review.id)
            witness.codes.append(code)
            let listed = await fixture.manager.plugins()
            witness.foundInstalled = listed.contains { $0.id == review.id && !$0.isEnabled }
        })
        _ = await model.importArchive(try fixture.archive(version: "1.0.0"))
        await model.install()
        XCTAssertNil(model.review)
        XCTAssertEqual(model.installedID, fixture.id)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.errorCode, "cleanupFailed")
        XCTAssertEqual(model.errorMessage, "插件已安装并保持停用，但部分恢复文件未能清理。")
        XCTAssertEqual(witness.ids, [fixture.id])
        XCTAssertEqual(witness.codes, ["cleanupFailed"])
        XCTAssertTrue(witness.foundInstalled)
    }

    func testCancelCleanupFailurePreventsCommitAndTerminationUntilRetrySucceeds() async throws {
        let fixture = try await InstallerUIFixture.make()
        defer { fixture.cleanup() }
        let handler = InstallerFailureHandler(installer: fixture.installer, mode: .cancelFailedOnce)
        let model = PluginInstallerModel(installer: handler)
        _ = await model.importArchive(try fixture.archive(version: "1.0.0"))
        let terminated = await model.shutdown()
        XCTAssertFalse(terminated)
        XCTAssertFalse(model.isTerminating)
        XCTAssertTrue(model.requiresCleanup)
        XCTAssertNotNil(model.review)
        await model.install()
        let commits = await handler.commitCalls
        XCTAssertEqual(commits, 0)
        let retried = await model.shutdown()
        XCTAssertTrue(retried)
        XCTAssertNil(model.review)
        XCTAssertFalse(model.requiresCleanup)
        XCTAssertEqual(try fixture.stagedCount(), 0)
    }

    func testConsumedPreparationReviewExposesOnlyOwnedStageCleanupAndCanRetryImport() async throws {
        let fixture = try await InstallerUIFixture.make()
        defer { fixture.cleanup() }
        let handler = InstallerFailureHandler(installer: fixture.installer, mode: .prepareCleanupFailedOnce)
        let model = PluginInstallerModel(installer: handler)
        let archive = try fixture.archive(version: "1.0.0")
        let imported = await model.importArchive(archive)
        XCTAssertFalse(imported)
        XCTAssertNil(model.review)
        XCTAssertNil(model.installedID)
        XCTAssertTrue(model.requiresCleanup)
        XCTAssertTrue(model.hasPendingImport)
        XCTAssertEqual(model.errorCode, "cleanupFailed")
        XCTAssertEqual(try fixture.stagedCount(), 1)
        let blocked = await model.importArchive(archive)
        XCTAssertFalse(blocked)
        let cleaned = await model.retryCleanup()
        XCTAssertTrue(cleaned)
        XCTAssertFalse(model.requiresCleanup)
        XCTAssertFalse(model.hasPendingImport)
        XCTAssertEqual(try fixture.stagedCount(), 0)
        let retried = await model.importArchive(archive)
        XCTAssertTrue(retried)
        _ = await model.cancel()
    }

}

@MainActor
struct InstallerUIFixture {
    let id = "com.example.installer.ui"
    let configuration: PluginManagerConfiguration
    let manager: PluginManager
    let installer: PluginInstaller
    let lifecycle: PluginLifecycleBridge
    let permissions: PermissionManager
    let starts: InstallerStartsWitness

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InstallerUI-SECRET-PATH-\(UUID().uuidString)")
        let configuration = PluginManagerConfiguration(rootDirectoryURL: root, hostVersion: try SemanticVersion("0.6.0"))
        let activities = ActivityManager(configuration: .immediate)
        let permissions = PermissionManager()
        let starts = InstallerStartsWitness()
        let lifecycle = PluginLifecycleBridge(activityManager: activities, actionRouter: ActionRouter(manager: activities),
            permissions: permissions, runtimeFactory: { _ in InstallerNeverStartedRuntime(witness: starts) })
        let manager = PluginManager(configuration: configuration, lifecycleHandler: lifecycle)
        let report = await manager.discover()
        XCTAssertTrue(report.failures.isEmpty)
        return .init(configuration: configuration, manager: manager,
                     installer: PluginInstaller(manager: manager, configuration: configuration),
                     lifecycle: lifecycle, permissions: permissions, starts: starts)
    }

    func archive(version: String, permissions: [PluginPermission] = [.readClipboard],
                 engine: PluginEngine = .javaScriptCore) throws -> URL {
        let manifest = try PluginManifest(id: id, name: "Installer Fixture", version: SemanticVersion(version),
            engine: engine, entry: "main.js", minimumHostVersion: SemanticVersion("0.6.0"),
            permissions: permissions, capabilities: [.publishActivity], developer: "Fixture Developer")
        let output = configuration.rootDirectoryURL.appendingPathComponent("SECRET-SOURCE-\(UUID().uuidString).dip")
        let entries = [("manifest.json", try manifest.encodeJSON()), ("main.js", Data("function onStart() {}".utf8))]
        try Self.storedZip(entries).write(to: output)
        return output
    }

    func stagedCount() throws -> Int {
        let stage = configuration.rootDirectoryURL.appendingPathComponent("Staging", isDirectory: true)
        guard FileManager.default.fileExists(atPath: stage.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil).count
    }

    func cleanup() {
        lifecycle.shutdown()
        try? FileManager.default.removeItem(at: configuration.rootDirectoryURL)
    }

    static func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The Host installation operation did not complete.")
        throw InstallerUIFixtureError.timedOut
    }

    private static func storedZip(_ entries: [(String, Data)]) -> Data {
        var archive = Data()
        var central = Data()
        for (name, data) in entries {
            let nameBytes = Data(name.utf8)
            let offset = UInt32(archive.count)
            let crc = data.withUnsafeBytes { buffer in
                UInt32(crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)))
            }
            archive.appendLE(UInt32(0x04034b50)); archive.appendLE(UInt16(20)); archive.appendLE(UInt16(0x800))
            archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
            archive.appendLE(crc); archive.appendLE(UInt32(data.count)); archive.appendLE(UInt32(data.count))
            archive.appendLE(UInt16(nameBytes.count)); archive.appendLE(UInt16(0)); archive.append(nameBytes); archive.append(data)
            central.appendLE(UInt32(0x02014b50)); central.appendLE(UInt16(0x0314)); central.appendLE(UInt16(20))
            central.appendLE(UInt16(0x800)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(crc); central.appendLE(UInt32(data.count)); central.appendLE(UInt32(data.count))
            central.appendLE(UInt16(nameBytes.count)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt32(0o100600) << 16)
            central.appendLE(offset); central.append(nameBytes)
        }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.appendLE(UInt32(0x06054b50)); archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(entries.count)); archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt32(central.count)); archive.appendLE(centralOffset); archive.appendLE(UInt16(0))
        return archive
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

@MainActor
private final class InstallerSourceAccessWitness: PluginArchiveAccessing {
    let grantsScope: Bool
    var started: [URL] = []
    var stopped: [URL] = []
    init(grantsScope: Bool = true) { self.grantsScope = grantsScope }
    func start(_ url: URL) -> Bool { started.append(url); return grantsScope }
    func stop(_ url: URL) { stopped.append(url) }
}

@MainActor
private final class InstallerInstalledWitness { var ids: [String] = [] }
@MainActor
private final class InstallerPresentationWitness { var count = 0 }
@MainActor
final class InstallerStartsWitness { var value = 0 }
@MainActor
private final class InstallerNeverStartedRuntime: PluginLifecycleRuntime {
    let witness: InstallerStartsWitness
    init(witness: InstallerStartsWitness) { self.witness = witness }
    func onStart(context: PluginExecutionContext) throws { witness.value += 1 }
    func onStop(reason: PluginStopReason) throws {}
    func teardown() {}
}

private actor InstallerPreparationGate: PluginInstallationHandling {
    let installer: PluginInstaller
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(installer: PluginInstaller) { self.installer = installer }
    func prepare(archiveURL: URL) async throws -> PluginInstallReview {
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
        return try await installer.prepare(archiveURL: archiveURL)
    }
    func commit(_ review: PluginInstallReview) async throws -> PluginRecord { try await installer.commit(review) }
    func cancel(_ review: PluginInstallReview) async throws { try await installer.cancel(review) }
    func hasPendingCleanup() async -> Bool { await installer.hasPendingCleanup() }
    func retryCleanup() async throws { try await installer.retryCleanup() }
    func release() {
        isOpen = true
        let current = waiters; waiters.removeAll(); current.forEach { $0.resume() }
    }
}
private enum InstallerUIFixtureError: Error { case timedOut }

@MainActor
private final class InstallerFailureWitness {
    var ids: [String] = []
    var codes: [String] = []
    var foundInstalled = false
}

private actor InstallerFailureHandler: PluginInstallationHandling {
    enum Mode { case commitFailed, committedCleanupFailed, cancelFailedOnce, prepareCleanupFailedOnce }
    let installer: PluginInstaller
    let mode: Mode
    private var cancelledOnce = false
    private var failedPrepareOnce = false
    private var cleanupReview: PluginInstallReview?
    private(set) var commitCalls = 0
    init(installer: PluginInstaller, mode: Mode) { self.installer = installer; self.mode = mode }
    func prepare(archiveURL: URL) async throws -> PluginInstallReview {
        let review = try await installer.prepare(archiveURL: archiveURL)
        if mode == .prepareCleanupFailedOnce && !failedPrepareOnce {
            failedPrepareOnce = true
            cleanupReview = review
            throw PluginInstallerError.cleanupFailed
        }
        return review
    }
    func commit(_ review: PluginInstallReview) async throws -> PluginRecord {
        commitCalls += 1
        switch mode {
        case .commitFailed:
            try await installer.cancel(review)
            throw PluginInstallerError.installFailed
        case .committedCleanupFailed:
            _ = try await installer.commit(review)
            throw PluginInstallerError.cleanupFailed
        case .cancelFailedOnce, .prepareCleanupFailedOnce:
            return try await installer.commit(review)
        }
    }
    func hasPendingCleanup() async -> Bool {
        if cleanupReview != nil { return true }
        return await installer.hasPendingCleanup()
    }
    func retryCleanup() async throws {
        if let review = cleanupReview {
            try await installer.cancel(review)
            cleanupReview = nil
        }
        try await installer.retryCleanup()
    }
    func cancel(_ review: PluginInstallReview) async throws {
        if mode == .cancelFailedOnce && !cancelledOnce {
            cancelledOnce = true
            throw PluginInstallerError.cleanupFailed
        }
        try await installer.cancel(review)
    }
}
