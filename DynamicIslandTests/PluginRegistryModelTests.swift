import CryptoKit
import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginRegistryModelTests: XCTestCase {
    func testDiscoveryStartsOfflineAndRefreshPublishesOnlyAValidCatalog() async throws {
        let f = try await RegistryUIFixture.make()
        defer { f.base.cleanup() }
        let loader = RegistryCatalogLoader(.success(f.catalog))
        let model = f.discovery(loader: { try await loader.load($0) })
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.entries.isEmpty)
        let before = await loader.calls
        XCTAssertEqual(before, 0)
        XCTAssertNoThrow(try PluginRegistryURLPolicy.catalog(PluginRegistryModel.officialSource))
        await model.refresh()
        XCTAssertEqual(model.entries, [f.entry])
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertTrue(model.canDownload(f.entry))
        XCTAssertEqual(f.base.starts.value, 0)
        XCTAssertEqual(try f.base.stagedCount(), 0)
    }

    func testRefreshFailureClearsPreviousEntriesAndUsesFixedMessages() async throws {
        let f = try await RegistryUIFixture.make()
        defer { f.base.cleanup() }
        let loader = RegistryCatalogLoader(.success(f.catalog))
        let model = f.discovery(loader: { try await loader.load($0) })
        await model.refresh()
        await loader.set(.failure(PluginRegistryError.httpStatus))
        await model.refresh()
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertEqual(model.errorCode, "httpStatus")
        XCTAssertTrue(model.errorMessage?.contains("尚未发布") == true)
        XCTAssertFalse(model.canDownload(f.entry))
        await loader.set(.failure(NSError(domain: "SECRET-URL-TOKEN", code: 1)))
        await model.refresh()
        XCTAssertEqual(model.errorCode, "transportFailed")
        XCTAssertFalse(model.errorMessage?.contains("SECRET") == true)
        await loader.set(.success(try RegistryUIFixture.catalog([])))
        await model.refresh()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testCancelRefreshDropsLateSuccessAndRejectsOverlappingRefresh() async throws {
        let f = try await RegistryUIFixture.make()
        defer { f.base.cleanup() }
        let gate = RegistryAsyncGate()
        let loader = RegistryCatalogLoader(.success(f.catalog), gate: gate)
        let model = f.discovery(loader: { try await loader.load($0) })
        let refresh = Task { await model.refresh() }
        try await InstallerUIFixture.wait { model.phase == .loading }
        await model.refresh()
        model.cancelRefresh()
        XCTAssertEqual(model.phase, .cancelling)
        XCTAssertFalse(model.canRefresh)
        await gate.release()
        await refresh.value
        let calls = await loader.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.entries.isEmpty, "An uncooperative late loader cannot repopulate a cancelled view.")
        XCTAssertTrue(model.canRefresh)
        await model.refresh()
        XCTAssertEqual(model.entries, [f.entry])
    }

    func testShutdownCancelsRefreshAndExplicitlyResumesAfterAbandonedQuit() async throws {
        let f = try await RegistryUIFixture.make()
        defer { f.base.cleanup() }
        let gate = RegistryAsyncGate()
        let model = f.discovery(loader: { _ in await gate.wait(); return f.catalog })
        let refresh = Task { await model.refresh() }
        try await InstallerUIFixture.wait { model.isRefreshing }
        let shutdown = Task { await model.shutdown() }
        try await InstallerUIFixture.wait { model.isTerminating }
        await gate.release()
        await shutdown.value
        await refresh.value
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertFalse(model.canRefresh)
        model.resumeAfterCancelledTermination()
        XCTAssertTrue(model.canRefresh)
    }

    func testDownloadRequiresCurrentExactEntryAndCompatibleHost() async throws {
        let f = try await RegistryUIFixture.make()
        defer { f.base.cleanup() }
        let older = PluginRegistryModel(hostVersion: try SemanticVersion("0.5.0"), installerModel: f.installer,
            loadCatalog: { _ in f.catalog })
        await older.refresh()
        XCTAssertFalse(older.isCompatible(f.entry))
        let rejectedOldHost = await older.download(f.entry)
        XCTAssertFalse(rejectedOldHost)
        let loader = RegistryCatalogLoader(.success(f.catalog))
        let model = f.discovery(loader: { try await loader.load($0) })
        let beforeRefresh = await model.download(f.entry)
        XCTAssertFalse(beforeRefresh)
        await model.refresh()
        let changed = try RegistryUIFixture.entry(bytes: f.bytes, version: "2.0.0")
        XCTAssertFalse(model.canDownload(changed))
        await loader.set(.success(try RegistryUIFixture.catalog([changed])))
        await model.refresh()
        XCTAssertFalse(model.canDownload(f.entry), "An old button cannot select stale catalog metadata.")
        XCTAssertEqual(try f.base.stagedCount(), 0)
    }

    func testRegistryPreviewUsesExistingInstallConsentAndKeepsPermissionsRequested() async throws {
        let f = try await RegistryUIFixture.make()
        defer { f.base.cleanup() }
        let model = f.discovery(loader: { _ in f.catalog })
        await model.refresh()
        let prepared = await model.download(f.entry)
        XCTAssertTrue(prepared)
        XCTAssertEqual(f.installer.phase, .reviewing)
        XCTAssertEqual(f.installer.review?.id, f.entry.id)
        XCTAssertFalse(model.canDownload(f.entry))
        XCTAssertFalse(model.canRefresh)
        let before = await f.base.manager.plugins()
        XCTAssertTrue(before.isEmpty)
        XCTAssertEqual(f.base.starts.value, 0)
        await f.installer.install()
        XCTAssertEqual(f.installer.installedID, f.entry.id)
        let installed = await f.base.manager.plugins()
        XCTAssertFalse(try XCTUnwrap(installed.first).isEnabled)
        let validated = await f.base.manager.validatedPackage(id: f.entry.id)
        let permissions = try f.base.permissions.snapshot(package: XCTUnwrap(validated))
        XCTAssertTrue(permissions.states.values.allSatisfy { $0 == .requested })
        XCTAssertEqual(f.base.starts.value, 0)
        XCTAssertTrue(model.canRefresh)
    }

    func testLocalImportAndCoordinatorCannotReplaceDownloadingRegistryReview() async throws {
        let f = try await RegistryUIFixture.make()
        defer { f.base.cleanup() }
        let prepared = try await f.base.installer.prepare(archiveData: f.bytes, registryEntry: f.entry)
        let gate = RegistryAsyncGate()
        let model = PluginInstallerModel(installer: f.base.installer, registryPrepare: { _ in
            await gate.wait(); return prepared
        })
        let downloading = Task { await model.importRegistryEntry(f.entry) }
        try await InstallerUIFixture.wait { model.canCancelDownload }
        let local = await model.importArchive(f.archive)
        XCTAssertFalse(local)
        let second = await model.importRegistryEntry(f.entry)
        XCTAssertFalse(second)
        let coordinator = PluginImportCoordinator(onPresent: {})
        coordinator.configure(model: model)
        coordinator.enqueue([f.archive])
        XCTAssertEqual(coordinator.pendingCount, 0)
        XCTAssertEqual(model.errorCode, "busy")
        let cancellation = Task { await model.cancel() }
        try await InstallerUIFixture.wait { model.isCancellingDownload }
        await gate.release()
        let finished = await downloading.value
        let cancelled = await cancellation.value
        XCTAssertFalse(finished)
        XCTAssertTrue(cancelled)
        XCTAssertNil(model.review)
        XCTAssertEqual(try f.base.stagedCount(), 0)
        XCTAssertFalse(model.hasPendingImport)
    }

    func testCallerCancellationCleansLateSuccessfulReview() async throws {
        let f = try await RegistryUIFixture.make()
        defer { f.base.cleanup() }
        let review = try await f.base.installer.prepare(archiveData: f.bytes, registryEntry: f.entry)
        let gate = RegistryAsyncGate()
        let model = PluginInstallerModel(installer: f.base.installer, registryPrepare: { _ in await gate.wait(); return review })
        let task = Task { await model.importRegistryEntry(f.entry) }
        try await InstallerUIFixture.wait { model.canCancelDownload }
        task.cancel()
        await gate.release()
        let accepted = await task.value
        XCTAssertFalse(accepted)
        XCTAssertNil(model.review)
        XCTAssertEqual(try f.base.stagedCount(), 0)
    }

    func testShutdownCleansLateReviewAndNeverPublishesInstallableSuccess() async throws {
        let f = try await RegistryUIFixture.make()
        defer { f.base.cleanup() }
        let review = try await f.base.installer.prepare(archiveData: f.bytes, registryEntry: f.entry)
        let gate = RegistryAsyncGate()
        let model = PluginInstallerModel(installer: f.base.installer, registryPrepare: { _ in await gate.wait(); return review })
        let task = Task { await model.importRegistryEntry(f.entry) }
        try await InstallerUIFixture.wait { model.canCancelDownload }
        let shutdown = Task { await model.shutdown() }
        try await InstallerUIFixture.wait { model.isTerminating }
        await gate.release()
        let accepted = await task.value
        let cleaned = await shutdown.value
        XCTAssertFalse(accepted)
        XCTAssertTrue(cleaned)
        XCTAssertFalse(model.hasPendingImport)
        XCTAssertEqual(try f.base.stagedCount(), 0)
        let afterwards = await model.importRegistryEntry(f.entry)
        XCTAssertFalse(afterwards)
    }

    func testCancelledLateReviewCleanupFailureBlocksNextImportUntilExplicitRetry() async throws {
        let f = try await RegistryUIFixture.make()
        defer { f.base.cleanup() }
        let review = try await f.base.installer.prepare(archiveData: f.bytes, registryEntry: f.entry)
        let handler = RegistryFailingCleanup(installer: f.base.installer)
        let gate = RegistryAsyncGate()
        let model = PluginInstallerModel(installer: handler, registryPrepare: { _ in await gate.wait(); return review })
        let task = Task { await model.importRegistryEntry(f.entry) }
        try await InstallerUIFixture.wait { model.canCancelDownload }
        let cancellation = Task { await model.cancel() }
        try await InstallerUIFixture.wait { model.isCancellingDownload }
        await gate.release()
        _ = await task.value
        let cleaned = await cancellation.value
        XCTAssertFalse(cleaned)
        XCTAssertEqual(model.review, review)
        XCTAssertTrue(model.requiresCleanup)
        XCTAssertTrue(model.hasPendingImport)
        XCTAssertEqual(model.errorCode, "cleanupFailed")
        let blocked = await model.importArchive(f.archive)
        XCTAssertFalse(blocked)
        await handler.allowCleanup()
        let retried = await model.retryCleanup()
        XCTAssertTrue(retried)
        XCTAssertEqual(try f.base.stagedCount(), 0)
        XCTAssertFalse(model.hasPendingImport)
    }

    func testRegistryFailuresAreFixedAndLeaveInstallerReusable() async throws {
        let f = try await RegistryUIFixture.make()
        defer { f.base.cleanup() }
        for failure: Error in [PluginInstallerError.archiveChecksumMismatch, PluginInstallerError.registryMismatch,
                               PluginRegistryError.httpStatus, PluginRegistryError.cancelled,
                               NSError(domain: "SECRET-DOWNLOAD-URL", code: 42)] {
            let model = PluginInstallerModel(installer: f.base.installer, registryPrepare: { _ in throw failure })
            let accepted = await model.importRegistryEntry(f.entry)
            XCTAssertFalse(accepted)
            XCTAssertFalse(model.hasPendingImport)
            XCTAssertNil(model.review)
            XCTAssertFalse(model.errorMessage?.contains("SECRET") == true)
            XCTAssertNotNil(model.errorCode)
            let imported = await model.importArchive(f.archive)
            XCTAssertTrue(imported)
            _ = await model.cancel()
        }
    }
}

@MainActor
struct RegistryUIFixture {
    let base: InstallerUIFixture
    let archive: URL
    let bytes: Data
    let entry: PluginRegistryEntry
    let catalog: PluginRegistryCatalog
    let installer: PluginInstallerModel

    static func make() async throws -> Self {
        let base = try await InstallerUIFixture.make()
        let archive = try base.archive(version: "1.0.0", permissions: [.readClipboard, .writeClipboard])
        let bytes = try Data(contentsOf: archive)
        let entry = try entry(bytes: bytes)
        let installer = PluginInstallerModel(installer: base.installer, registryPrepare: { entry in
            try await base.installer.prepare(archiveData: bytes, registryEntry: entry)
        })
        return .init(base: base, archive: archive, bytes: bytes, entry: entry, catalog: try catalog([entry]), installer: installer)
    }

    func discovery(loader: @escaping @Sendable (URL) async throws -> PluginRegistryCatalog) -> PluginRegistryModel {
        .init(hostVersion: base.configuration.hostVersion, installerModel: installer, loadCatalog: loader)
    }

    static func entry(bytes: Data, version: String = "1.0.0", minimum: String = "0.6.0",
                      id: String = "com.example.installer.ui", name: String = "Installer Fixture") throws -> PluginRegistryEntry {
        let fields: [String: String] = ["id": id, "name": name, "version": version,
            "minHostVersion": minimum, "source": "https://github.com/example/plugins",
            "download": "https://github.com/example/plugins/releases/download/v1/fixture.dip",
            "hash": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
        return try XCTUnwrap(PluginRegistryCatalog.decode(JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "plugins": [fields]
        ])).entries.first)
    }

    static func catalog(_ entries: [PluginRegistryEntry]) throws -> PluginRegistryCatalog {
        try PluginRegistryCatalog.decode(JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "plugins": entries.map {
            ["id": $0.id, "name": $0.name, "version": $0.version.description, "source": $0.source.absoluteString,
             "download": $0.download.absoluteString, "minHostVersion": $0.minHostVersion.description, "hash": $0.hash]
        }]))
    }
}

actor RegistryAsyncGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !released { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}

private actor RegistryCatalogLoader {
    var result: Result<PluginRegistryCatalog, Error>
    let gate: RegistryAsyncGate?
    private(set) var calls = 0
    init(_ result: Result<PluginRegistryCatalog, Error>, gate: RegistryAsyncGate? = nil) { self.result = result; self.gate = gate }
    func set(_ result: Result<PluginRegistryCatalog, Error>) { self.result = result }
    func load(_ url: URL) async throws -> PluginRegistryCatalog { calls += 1; await gate?.wait(); return try result.get() }
}

private actor RegistryFailingCleanup: PluginInstallationHandling {
    let installer: PluginInstaller
    var fail = true
    init(installer: PluginInstaller) { self.installer = installer }
    func allowCleanup() { fail = false }
    func prepare(archiveURL: URL) async throws -> PluginInstallReview { try await installer.prepare(archiveURL: archiveURL) }
    func cancel(_ review: PluginInstallReview) async throws {
        if fail { throw PluginInstallerError.cleanupFailed }
        try await installer.cancel(review)
    }
    func commit(_ review: PluginInstallReview) async throws -> PluginRecord { try await installer.commit(review) }
    func hasPendingCleanup() async -> Bool { await installer.hasPendingCleanup() }
    func retryCleanup() async throws { try await installer.retryCleanup() }
}
