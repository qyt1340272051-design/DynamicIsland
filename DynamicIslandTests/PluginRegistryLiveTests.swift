import Foundation
import XCTest
@testable import DynamicIsland

/// Opt-in public-network coverage. This exercises Host models and a real VM;
/// it does not replace the separate AppKit, hover, browser or author walkthrough gates.
@MainActor
final class PluginRegistryLiveTests: XCTestCase {
    private let officialRepository = "https://github.com/qyt1340272051-design/DynamicIsland"
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testPublishedOfficialCatalogDownloadsInstallsAndRestoresExplicitPermissionsAndExecutions() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DYNAMIC_ISLAND_LIVE_REGISTRY"] == "1" else {
            throw XCTSkip("Public-network acceptance is opt-in: set DYNAMIC_ISLAND_LIVE_REGISTRY=1.")
        }
        let source = try catalogSource(environment["DYNAMIC_ISLAND_LIVE_REGISTRY_CATALOG_URL"])
        print("LIVE_REGISTRY catalog=\(source.absoluteString) defaultSource=\(source == PluginRegistryModel.officialSource)")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("registry-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try LiveRegistryHost(root: root, source: source)
        defer { first.stopExecutions() }
        var restarted: LiveRegistryHost?
        defer { restarted?.stopExecutions() }

        do {
            let initial = await first.manager.discover()
            XCTAssertTrue(initial.failures.isEmpty)
            XCTAssertTrue(initial.plugins.isEmpty)
            XCTAssertEqual(first.registry.phase, .idle)
            XCTAssertTrue(first.registry.entries.isEmpty)
            await first.registry.refresh()
            XCTAssertEqual(first.registry.phase, .loaded, first.registry.errorCode ?? "Catalog did not load")
            XCTAssertNil(first.registry.errorMessage)
            XCTAssertNil(first.registry.errorCode)

            let specifications: [LiveRegistrySpecification] = [
                .init(id: "com.dynamicisland.pomodoro", name: "番茄钟", version: "0.2.1",
                      archive: "pomodoro-0.2.1.dip", example: "pomodoro", permissions: [.localStorage]),
                .init(id: "com.dynamicisland.github", name: "GitHub", version: "0.1.0",
                      archive: "github-0.1.0.dip", example: "github", permissions: [.network, .localStorage, .openLinks])
            ]
            for specification in specifications {
                let entry = try XCTUnwrap(first.registry.entries.first { $0.id == specification.id }, "Missing published official entry")
                XCTAssertEqual(entry.name, specification.name)
                XCTAssertEqual(entry.version.description, specification.version)
                XCTAssertEqual(entry.minHostVersion.description, "0.6.0")
                XCTAssertEqual(entry.source.absoluteString, officialRepository)
                XCTAssertEqual(entry.download.absoluteString, officialRepository + "/releases/download/plugins-0.6.0/" + specification.archive)
                print("LIVE_REGISTRY package=\(entry.id) version=\(entry.version) sha256=\(entry.hash)")

                let before = await first.manager.plugins()
                XCTAssertTrue(first.registry.canDownload(entry))
                let downloaded = await first.registry.download(entry)
                XCTAssertTrue(downloaded, first.installerModel.errorCode ?? "Download did not reach preview")
                XCTAssertEqual(first.installerModel.phase, .reviewing)
                let review = try XCTUnwrap(first.installerModel.review, first.installerModel.errorMessage ?? "Missing install review")
                XCTAssertEqual(review.id, specification.id)
                XCTAssertEqual(review.name, entry.name)
                XCTAssertEqual(review.version, entry.version)
                XCTAssertEqual(review.developer, "DynamicIsland")
                XCTAssertEqual(review.engine, .javaScriptCore)
                XCTAssertEqual(Set(review.permissions), Set(specification.permissions))
                XCTAssertNil(review.previousVersion)
                let stillBefore = await first.manager.plugins()
                XCTAssertEqual(stillBefore.map(\.id), before.map(\.id), "Downloading and reviewing may not install code")
                XCTAssertNil(first.lifecycle.snapshot(id: specification.id))
                XCTAssertNil(first.tool(id: specification.id), "Preview may not execute JavaScript")

                // This is the same explicit confirmation method used by the install UI.
                await first.installerModel.install()
                XCTAssertNil(first.installerModel.errorCode)
                XCTAssertNil(first.installerModel.errorMessage)
                XCTAssertEqual(first.installerModel.installedID, specification.id)
                let recordValue = await first.manager.plugin(id: specification.id)
                let record = try XCTUnwrap(recordValue)
                XCTAssertFalse(record.isEnabled, "Installing is not enabling")
                XCTAssertEqual(record.manifest.version, entry.version)
                XCTAssertEqual(record.manifest.name, entry.name)
                XCTAssertEqual(record.manifest.minimumHostVersion, entry.minHostVersion)
                XCTAssertEqual(Set(record.manifest.permissions), Set(specification.permissions))
                XCTAssertEqual(record.regularFileCount, 4)
                let files = try FileManager.default.contentsOfDirectory(atPath: record.canonicalRootURL.path)
                XCTAssertEqual(Set(files), ["manifest.json", "index.js", "README.md", "LICENSE"])
                XCTAssertEqual(try Data(contentsOf: record.canonicalRootURL.appendingPathComponent("LICENSE")),
                               try Data(contentsOf: repository.appendingPathComponent("LICENSE")))
                let packageValue = await first.manager.validatedPackage(id: specification.id)
                let package = try XCTUnwrap(packageValue)
                XCTAssertEqual(package.entrySource, try Data(contentsOf: repository.appendingPathComponent(
                    "docs/plugin-system/examples/\(specification.example)/index.js")))
                await first.extensions.refresh()
                try assertPermissions(specification, in: first, granted: [])
                XCTAssertEqual(first.lifecycle.snapshot(id: specification.id)?.state, .disabled)
                XCTAssertNil(first.tool(id: specification.id))
                try assertEmptyStaging(first)
            }

            var active: [String: ActivitySnapshot] = [:]
            for specification in specifications {
                // Enable once before approval: the VM may render its denied state,
                // but enablement must leave every declaration requested.
                await first.extensions.setEnabled(id: specification.id, isEnabled: true)
                XCTAssertNil(first.extensions.error)
                try await wait("Tool while permissions are requested: \(specification.id)") {
                    first.tool(id: specification.id) != nil
                }
                try assertPermissions(specification, in: first, granted: [])
                XCTAssertEqual(first.lifecycle.countdownBroker.diagnostics.recordCount, 0)
                await first.extensions.setEnabled(id: specification.id, isEnabled: false)
                XCTAssertNil(first.extensions.error)
                XCTAssertNil(first.tool(id: specification.id))

                var granted = Set<PluginPermission>()
                for permission in specification.permissions {
                    let review = try XCTUnwrap(first.extensions.permissionReview(id: specification.id))
                    // Explicit, individual Host decisions belong only to this
                    // temporary test store. Enable never supplies these grants.
                    await first.extensions.setPermission(decision: .granted, review: review, permission: permission)
                    XCTAssertNil(first.extensions.error)
                    XCTAssertNil(first.extensions.persistenceError)
                    granted.insert(permission)
                    try assertPermissions(specification, in: first, granted: granted)
                }
                await first.extensions.setEnabled(id: specification.id, isEnabled: true)
                XCTAssertNil(first.extensions.error)
                try await wait("Granted tool: \(specification.id)") { first.tool(id: specification.id) != nil }
                let snapshot = try XCTUnwrap(first.tool(id: specification.id))
                active[specification.id] = snapshot
                XCTAssertEqual(first.lifecycle.snapshot(id: specification.id)?.state, .running)
                XCTAssertNil(first.lifecycle.snapshot(id: specification.id)?.lastFailure)

                if specification.id == "com.dynamicisland.pomodoro" {
                    XCTAssertEqual(snapshot.activity.presentation.subtitle, "25 分钟 · 准备专注")
                    first.activities.setPresentationContext(.expanded)
                    XCTAssertTrue(first.activities.selectTool(snapshot))
                    XCTAssertEqual(first.dispatch(snapshot, actionID: "preset.15"), .handled)
                    try await wait("Preset must traverse the actual router, VM and durable storage") {
                        let settings = try await first.storage.get(pluginID: specification.id, key: "settings")
                        guard case .object(let fields) = settings else { return false }
                        return fields["selectedMinutes"] == .number(15) && fields["lastSession"] == .string("idle")
                            && first.tool(id: specification.id)?.activity.presentation.subtitle == "15 分钟 · 准备专注"
                    }
                    XCTAssertEqual(first.lifecycle.countdownBroker.diagnostics.recordCount, 0, "Choosing a preset must not start a timer")
                }
                // GitHub's granted startup uses the real anonymous public API.
                // Tool publication is the bounded gate; live CI/PR contents and
                // external browser opening are deliberately not asserted here.
            }

            for specification in specifications {
                let previous = try XCTUnwrap(active[specification.id])
                await first.extensions.setEnabled(id: specification.id, isEnabled: false)
                XCTAssertNil(first.extensions.error)
                XCTAssertNil(first.tool(id: specification.id))
                XCTAssertEqual(first.dispatch(previous, actionID: specification.example == "pomodoro" ? "preset.15" : "refresh"), .inactiveActivity)
                try assertPermissions(specification, in: first, granted: Set(specification.permissions))
            }
            var beforeRestart: [String: ActivitySnapshot] = [:]
            for specification in specifications {
                await first.extensions.setEnabled(id: specification.id, isEnabled: true)
                XCTAssertNil(first.extensions.error)
                try await wait("Reenabled tool: \(specification.id)") { first.tool(id: specification.id) != nil }
                let replacement = try XCTUnwrap(first.tool(id: specification.id))
                XCTAssertNotEqual(replacement.instanceToken, active[specification.id]?.instanceToken)
                beforeRestart[specification.id] = replacement
            }
            let firstCleaned = await first.shutdown()
            XCTAssertTrue(firstCleaned)
            XCTAssertTrue(first.activities.toolSnapshots.isEmpty)
            try assertEmptyStaging(first)

            // A fresh graph must discover actual disk state, not retained VM or
            // PermissionManager objects from the first execution.
            let second = try LiveRegistryHost(root: root, source: source)
            restarted = second
            let rediscovered = await second.manager.discover()
            XCTAssertTrue(rediscovered.failures.isEmpty)
            XCTAssertEqual(Set(rediscovered.plugins.map(\.id)), Set(specifications.map(\.id)))
            XCTAssertTrue(rediscovered.plugins.allSatisfy(\.isEnabled))
            await second.extensions.refresh()
            for specification in specifications {
                try assertPermissions(specification, in: second, granted: Set(specification.permissions))
                try await wait("Restored tool: \(specification.id)") { second.tool(id: specification.id) != nil }
                let replacement = try XCTUnwrap(second.tool(id: specification.id))
                let old = try XCTUnwrap(beforeRestart[specification.id])
                XCTAssertNotEqual(replacement.instanceToken, old.instanceToken)
                XCTAssertEqual(second.dispatch(old, actionID: specification.example == "pomodoro" ? "preset.15" : "refresh"), .inactiveActivity)
                XCTAssertEqual(second.lifecycle.snapshot(id: specification.id)?.state, .running)
                XCTAssertNil(second.lifecycle.snapshot(id: specification.id)?.lastFailure)
            }
            XCTAssertEqual(second.tool(id: "com.dynamicisland.pomodoro")?.activity.presentation.subtitle, "15 分钟 · 准备专注")
            XCTAssertEqual(second.lifecycle.countdownBroker.diagnostics.recordCount, 0, "Restart must not automatically begin a countdown")
            let secondCleaned = await second.shutdown()
            XCTAssertTrue(secondCleaned)
            try assertEmptyStaging(second)
            print("LIVE_REGISTRY observed=real-download,explicit-install,disabled-requested,individual-grants,vm-tool,preset-storage,stale-actions,restart,empty-staging")
        } catch {
            _ = await first.shutdown()
            if let restarted { _ = await restarted.shutdown() }
            throw error
        }
    }

    private func catalogSource(_ override: String?) throws -> URL {
        guard let override else { return PluginRegistryModel.officialSource }
        let url = try XCTUnwrap(URL(string: override), "Invalid live Registry catalog override")
        // Production policy enforces canonical HTTPS, one portable ref, no
        // credentials, query, fragment, encoded path or alternate destination.
        try PluginRegistryURLPolicy.catalog(url)
        let parts = url.path.split(separator: "/").map(String.init)
        guard Array(parts.prefix(2)) == ["qyt1340272051-design", "DynamicIsland"] else {
            throw LiveRegistryTestError.invalidRepository
        }
        return url
    }

    private func assertPermissions(_ specification: LiveRegistrySpecification, in host: LiveRegistryHost,
                                   granted: Set<PluginPermission>, file: StaticString = #filePath, line: UInt = #line) throws {
        let snapshot = try XCTUnwrap(host.extensions.permissionSnapshots[specification.id], file: file, line: line)
        XCTAssertEqual(Set(snapshot.states.keys), Set(specification.permissions), file: file, line: line)
        for permission in specification.permissions {
            XCTAssertEqual(snapshot.states[permission], granted.contains(permission) ? .granted : .requested,
                           permission.rawValue, file: file, line: line)
        }
    }

    private func assertEmptyStaging(_ host: LiveRegistryHost, file: StaticString = #filePath, line: UInt = #line) throws {
        let entries = try FileManager.default.contentsOfDirectory(atPath: host.configuration.stagingDirectoryURL.path)
        XCTAssertTrue(entries.isEmpty, "Registry operations left staging reservations", file: file, line: line)
    }

    private func wait(_ description: String, _ predicate: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while true {
            if try await predicate() { return }
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out: \(description)")
                throw LiveRegistryTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private struct LiveRegistrySpecification {
    let id: String
    let name: String
    let version: String
    let archive: String
    let example: String
    let permissions: [PluginPermission]
}

@MainActor
private final class LiveRegistryHost {
    let configuration: PluginManagerConfiguration
    let storage: PluginStorage
    let activities: ActivityManager
    let router: ActionRouter
    let scheduler: PluginScheduler
    let lifecycle: PluginLifecycleBridge
    let manager: PluginManager
    let installerModel: PluginInstallerModel
    let registry: PluginRegistryModel
    let extensions: PluginExtensionsModel
    private var stopped = false

    init(root: URL, source: URL) throws {
        let configuration = PluginManagerConfiguration(rootDirectoryURL: root, hostVersion: try SemanticVersion("0.6.0"))
        let permissions = PermissionManager(decisionStore: PluginPermissionDecisionStore(configuration: .init(rootDirectoryURL: root)))
        let storage = PluginStorage(configuration: .init(rootDirectoryURL: root))
        let diagnostics = PluginDiagnosticsStore()
        let activities = ActivityManager(configuration: .immediate)
        let router = ActionRouter(manager: activities)
        // No timer is required for the bounded startup/preset contract. This
        // keeps background refresh scheduling from expanding the live test.
        let scheduler = PluginScheduler(policy: .background, automaticScheduling: false)
        let links = PluginLinkBroker(opener: { _ in
            XCTFail("A plugin opened a browser without an explicit link action")
            return false
        })
        let bridge = PluginJSBridge(storage: storage, permissions: permissions, network: PluginNetworkBroker(),
                                    links: links, scheduler: scheduler, diagnostics: diagnostics)
        let lifecycle = PluginLifecycleBridge(activityManager: activities, actionRouter: router, permissions: permissions,
                                              diagnostics: diagnostics, runtimeFactory: { package in
            PluginRuntime(package: package, bridge: bridge)
        })
        let manager = PluginManager(configuration: configuration, lifecycleHandler: lifecycle)
        let installer = PluginInstaller(manager: manager, configuration: configuration)
        // These are the production URLSession transport and immutable byte
        // path. There is no URLProtocol, local archive or download substitution.
        let client = PluginRegistryClient()
        let installerModel = PluginInstallerModel(installer: installer, registryPrepare: { entry in
            try await client.prepareDownload(entry, installer: installer)
        })
        self.configuration = configuration
        self.storage = storage
        self.activities = activities
        self.router = router
        self.scheduler = scheduler
        self.lifecycle = lifecycle
        self.manager = manager
        self.installerModel = installerModel
        registry = PluginRegistryModel(sourceURL: source, hostVersion: configuration.hostVersion,
                                       installerModel: installerModel, loadCatalog: { url in
            try await client.loadCatalog(from: url)
        })
        extensions = PluginExtensionsModel(manager: manager, lifecycle: lifecycle, permissions: permissions, diagnostics: diagnostics)
    }

    func tool(id: String) -> ActivitySnapshot? {
        activities.toolSnapshots.first { $0.activity.source.identifier == id }
    }

    func dispatch(_ snapshot: ActivitySnapshot, actionID: String) -> ActionDispatchResult {
        router.dispatch(id: snapshot.activity.id, source: snapshot.activity.source, instanceToken: snapshot.instanceToken,
                        action: .init(actionID: actionID, value: .none))
    }

    func stopExecutions() {
        guard !stopped else { return }
        stopped = true
        lifecycle.shutdown()
        scheduler.shutdown()
    }

    func shutdown() async -> Bool {
        stopExecutions()
        await registry.shutdown()
        return await installerModel.shutdown()
    }
}

private enum LiveRegistryTestError: Error { case invalidRepository, timedOut }
