import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginDiagnosticsUITests: XCTestCase {
    func testRefreshReadsRecordsAndKeepsSelectionUntilPluginIsRemoved() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let betaID = "com.example.diagnostics.beta"
        let beta = try makePackage(in: fixture.configuration.installedDirectoryURL, id: betaID, name: "Beta Plugin")
        _ = try await fixture.manager.load(at: beta)
        fixture.diagnostics.recordPluginMessage(pluginID: fixture.id, level: .info)
        fixture.diagnostics.recordPluginMessage(pluginID: betaID, level: .warning)

        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.plugins.count, 2)
        XCTAssertEqual(fixture.model.selectedID, fixture.id)
        fixture.model.selectedID = betaID
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.selectedID, betaID)
        XCTAssertEqual(fixture.model.selectedRecords.map(\.pluginID), [betaID])
        XCTAssertEqual(fixture.model.selectedRecords.first?.message, "Plugin log message omitted.")
        XCTAssertEqual(fixture.model.snapshots.count, 2)
        fixture.diagnostics.recordPluginMessage(pluginID: betaID, level: .info)
        try await waitUntil { fixture.model.selectedRecords.count == 2 }
        XCTAssertEqual(fixture.model.selectedRecords.count, 2)

        _ = try await fixture.manager.uninstall(id: betaID)
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.selectedID, fixture.id)
        XCTAssertEqual(fixture.model.plugins.count, 1)
        XCTAssertNil(fixture.model.snapshots[betaID])
        XCTAssertFalse(fixture.model.isBusy)
    }

    func testRestartReloadsDiskCodeRevokesOldContextAndPersistsEnablement() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.manager.enable(id: fixture.id)
        let oldContext = try XCTUnwrap(fixture.runtimeContexts.contexts.last)
        let replacement = "const revision = 2;"
        try Data(replacement.utf8).write(to: fixture.entryURL)

        await fixture.model.restart(id: fixture.id)

        XCTAssertNil(fixture.model.error)
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertEqual(fixture.runtimeContexts.creationCount, 2)
        XCTAssertThrowsError(try oldContext.perform {}) {
            XCTAssertEqual($0 as? PluginExecutionError, .inactiveExecution)
        }
        XCTAssertFalse(oldContext.reportSeriousFailure(kind: .actionException))
        let newContext = try XCTUnwrap(fixture.runtimeContexts.contexts.last)
        XCTAssertFalse(oldContext === newContext)
        XCTAssertNoThrow(try newContext.perform {})
        let package = await fixture.manager.validatedPackage(id: fixture.id)
        XCTAssertEqual(package?.entrySource, Data(replacement.utf8))
        XCTAssertEqual(fixture.model.selectedSnapshot?.state, .running)
        XCTAssertTrue(fixture.model.selectedPlugin?.isEnabled == true)
        XCTAssertEqual(fixture.model.selectedRecords.first?.code, "restartRequested")

        let relaunchedManager = PluginManager(configuration: fixture.configuration)
        let report = await relaunchedManager.discover()
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(report.plugins.first?.isEnabled == true)
        XCTAssertTrue(newContext.reportFailure(.startFailed))
        try await waitUntil { fixture.model.selectedSnapshot?.state == .stopped }
        XCTAssertEqual(fixture.model.selectedSnapshot?.lastFailure, .startFailed)
    }

    func testExplicitQuarantineRestartKeepsHistoryAndRejectsOldSession() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.manager.enable(id: fixture.id)
        let oldContext = try XCTUnwrap(fixture.runtimeContexts.contexts.last)
        XCTAssertTrue(oldContext.reportSeriousFailure(kind: .actionException))
        XCTAssertTrue(oldContext.reportSeriousFailure(kind: .actionRejection))
        XCTAssertTrue(oldContext.reportSeriousFailure(kind: .actionException))
        let firstIncident = try XCTUnwrap(fixture.lifecycle.snapshot(id: fixture.id)?.quarantine)
        await fixture.model.refresh()
        XCTAssertFalse(fixture.model.selectedSnapshot?.isEnabled == true)

        await fixture.model.restart(id: fixture.id)

        XCTAssertNil(fixture.model.error)
        XCTAssertNil(fixture.model.selectedSnapshot?.quarantine)
        XCTAssertEqual(fixture.model.selectedSnapshot?.state, .running)
        XCTAssertEqual(fixture.watchdog.snapshot(id: fixture.id)?.recentFailureCount, 3)
        XCTAssertFalse(oldContext.reportSeriousFailure(kind: .actionException))
        let current = try XCTUnwrap(fixture.runtimeContexts.contexts.last)
        XCTAssertTrue(current.reportSeriousFailure(kind: .actionRejection))
        let secondIncident = try XCTUnwrap(fixture.lifecycle.snapshot(id: fixture.id)?.quarantine)
        XCTAssertNotEqual(firstIncident.id, secondIncident.id)
        XCTAssertFalse(fixture.lifecycle.allowsExecution(id: fixture.id))
    }

    func testInvalidReloadLeavesPluginDisabledAndUsesFixedFailureText() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.manager.enable(id: fixture.id)
        let context = try XCTUnwrap(fixture.runtimeContexts.contexts.last)
        try FileManager.default.removeItem(at: fixture.entryURL)

        await fixture.model.restart(id: fixture.id)

        XCTAssertEqual(fixture.model.error, PluginDiagnosticsModel.restartFailedMessage)
        XCTAssertFalse(fixture.model.error?.contains("SECRET-PATH") == true)
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertFalse(fixture.model.selectedPlugin?.isEnabled == true)
        XCTAssertEqual(fixture.model.selectedSnapshot?.state, .disabled)
        XCTAssertEqual(fixture.runtimeContexts.creationCount, 1)
        XCTAssertThrowsError(try context.perform {})
        let retained = fixture.model.records.map(\.message).joined()
        XCTAssertFalse(retained.contains(fixture.configuration.rootDirectoryURL.path))
        XCTAssertFalse(retained.contains("SECRET-PATH"))
    }

    func testFailedStateWriteDoesNotReloadOrRetryAndReportsFixedCode() async throws {
        let stateStore = DiagnosticsUIStateStore()
        let fixture = try await makeFixture(stateStore: stateStore)
        defer { fixture.cleanup() }
        _ = try await fixture.manager.enable(id: fixture.id)
        let context = try XCTUnwrap(fixture.runtimeContexts.contexts.last)
        stateStore.setFailure(true)

        await fixture.model.restart(id: fixture.id)

        XCTAssertEqual(fixture.model.error, PluginDiagnosticsModel.restartFailedMessage)
        XCTAssertEqual(fixture.runtimeContexts.creationCount, 1)
        XCTAssertNoThrow(try context.perform {})
        XCTAssertEqual(fixture.model.selectedSnapshot?.state, .running)
        XCTAssertEqual(fixture.model.selectedRecords.first?.code, "stateWriteFailed")
        XCTAssertFalse(fixture.model.isBusy)
    }

    func testEmptyManagerRefreshProducesEmptySelectionAndNoRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiagnosticsEmpty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let activityManager = ActivityManager()
        let lifecycle = PluginLifecycleBridge(activityManager: activityManager, actionRouter: ActionRouter(manager: activityManager))
        let manager = PluginManager(configuration: .init(rootDirectoryURL: root, hostVersion: try SemanticVersion("0.6.0")),
                                    lifecycleHandler: lifecycle)
        _ = await manager.discover()
        let model = PluginDiagnosticsModel(manager: manager, lifecycle: lifecycle, diagnostics: PluginDiagnosticsStore())
        model.selectedID = "com.example.no.longer.installed"

        await model.refresh()

        XCTAssertTrue(model.plugins.isEmpty)
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.selectedPlugin)
        XCTAssertNil(model.selectedSnapshot)
        XCTAssertTrue(model.selectedRecords.isEmpty)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isBusy)
        lifecycle.shutdown()
    }

    func testNativeDiagnosticsWindowRendersQuarantineAndFixedRecordsToPNG() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.manager.enable(id: fixture.id)
        let context = try XCTUnwrap(fixture.runtimeContexts.contexts.last)
        fixture.diagnostics.recordPluginMessage(pluginID: fixture.id, level: .info)
        fixture.diagnostics.record(pluginID: fixture.id, level: .error, category: .actionFailure, code: .actionHandlerFailed)
        XCTAssertTrue(context.reportSeriousFailure(kind: .actionException))
        fixture.diagnostics.record(pluginID: fixture.id, level: .error, category: .actionFailure, code: .actionHandlerFailed)
        XCTAssertTrue(context.reportSeriousFailure(kind: .actionRejection))
        XCTAssertTrue(context.reportSeriousFailure(kind: .actionException))
        await fixture.model.refresh()

        let controller = PluginDiagnosticsWindowController(model: fixture.model)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        controller.show()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(window.title, "插件诊断")
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        XCTAssertGreaterThanOrEqual(view.bounds.width, 720)
        XCTAssertGreaterThanOrEqual(view.bounds.height, 480)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 2_000)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("dynamic-island-t32-diagnostics.png")
        try png.write(to: output, options: .atomic)
        print("T32_DIAGNOSTICS_SCREENSHOT=\(output.path)")
        XCTAssertEqual(fixture.model.selectedSnapshot?.state, .disabled)
        XCTAssertNotNil(fixture.model.selectedSnapshot?.quarantine)
        XCTAssertEqual(fixture.model.selectedRecords.first?.code, "automaticDisable")
    }

    private func makeFixture(stateStore: DiagnosticsUIStateStore? = nil) async throws -> DiagnosticsUIFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginDiagnosticsUI-SECRET-PATH-\(UUID().uuidString)", isDirectory: true)
        let configuration = PluginManagerConfiguration(rootDirectoryURL: root, hostVersion: try SemanticVersion("0.6.0"))
        let activities = ActivityManager()
        let diagnostics = PluginDiagnosticsStore()
        let watchdog = PluginCrashWatchdog(clock: { 100 })
        let runtimeContexts = DiagnosticsUIRuntimeContexts()
        let lifecycle = PluginLifecycleBridge(activityManager: activities, actionRouter: ActionRouter(manager: activities),
                                              watchdog: watchdog, diagnostics: diagnostics, runtimeFactory: { _ in
            runtimeContexts.creationCount += 1
            return DiagnosticsUIRuntime { [weak runtimeContexts] context in runtimeContexts?.contexts.append(context) }
        })
        let manager: PluginManager
        if let stateStore {
            manager = PluginManager(configuration: configuration, stateStore: stateStore, lifecycleHandler: lifecycle)
        } else {
            manager = PluginManager(configuration: configuration, lifecycleHandler: lifecycle)
        }
        let report = await manager.discover()
        XCTAssertTrue(report.failures.isEmpty)
        let id = "com.example.diagnostics.alpha"
        let packageURL = try makePackage(in: configuration.installedDirectoryURL, id: id, name: "Weather Mock")
        _ = try await manager.load(at: packageURL)
        let model = PluginDiagnosticsModel(manager: manager, lifecycle: lifecycle, diagnostics: diagnostics)
        return DiagnosticsUIFixture(id: id, configuration: configuration, entryURL: packageURL.appendingPathComponent("main.js"),
                                    manager: manager, lifecycle: lifecycle, diagnostics: diagnostics, watchdog: watchdog,
                                    runtimeContexts: runtimeContexts, model: model)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("A Host change did not refresh the diagnostics snapshot.")
    }

    private func makePackage(in installed: URL, id: String, name: String) throws -> URL {
        let root = installed.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let manifest = try PluginManifest(id: id, name: name, version: SemanticVersion("1.0.0"), engine: .javaScriptCore,
                                          entry: "main.js", minimumHostVersion: SemanticVersion("0.6.0"),
                                          permissions: [], capabilities: [])
        try manifest.encodeJSON().write(to: root.appendingPathComponent("manifest.json"))
        try Data("const revision = 1;".utf8).write(to: root.appendingPathComponent("main.js"))
        return root
    }
}

@MainActor
private struct DiagnosticsUIFixture {
    let id: String
    let configuration: PluginManagerConfiguration
    let entryURL: URL
    let manager: PluginManager
    let lifecycle: PluginLifecycleBridge
    let diagnostics: PluginDiagnosticsStore
    let watchdog: PluginCrashWatchdog
    let runtimeContexts: DiagnosticsUIRuntimeContexts
    let model: PluginDiagnosticsModel

    func cleanup() {
        lifecycle.shutdown()
        try? FileManager.default.removeItem(at: configuration.rootDirectoryURL)
    }
}

@MainActor
private final class DiagnosticsUIRuntimeContexts {
    var creationCount = 0
    var contexts: [PluginExecutionContext] = []
}

@MainActor
private final class DiagnosticsUIRuntime: PluginLifecycleRuntime {
    private let collect: (PluginExecutionContext) -> Void
    init(collect: @escaping (PluginExecutionContext) -> Void) { self.collect = collect }
    func onStart(context: PluginExecutionContext) throws { collect(context) }
    func onStop(reason: PluginStopReason) throws {}
    func teardown() {}
}

private nonisolated final class DiagnosticsUIStateStore: PluginManagerStatePersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var state = PluginManagerStateFile.empty
    private var fail = false

    func load() throws -> PluginManagerStateFile {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    func save(_ next: PluginManagerStateFile) throws {
        lock.lock(); defer { lock.unlock() }
        if fail { throw PluginManagerError.stateWriteFailed }
        state = next
    }

    func setFailure(_ value: Bool) { lock.lock(); fail = value; lock.unlock() }
}
