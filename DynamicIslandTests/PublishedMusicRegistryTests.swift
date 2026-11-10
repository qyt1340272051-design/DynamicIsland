import Foundation
import XCTest
@testable import DynamicIsland

/// Opt-in production Registry -> public Release -> Installer -> optional media
/// provider coverage. Only the system helper runner is mocked; this never
/// starts or controls a real player, nor touches the user's plugin container.
@MainActor
final class PublishedMusicRegistryTests: XCTestCase {
    func testPublishedMusicPackagesDownloadInstallAndRespectSeparateMediaPermissions() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DYNAMIC_ISLAND_LIVE_REGISTRY"] == "1" else {
            throw XCTSkip("Public-network acceptance is opt-in: set DYNAMIC_ISLAND_LIVE_REGISTRY=1.")
        }
        let source = try catalogSource(environment["DYNAMIC_ISLAND_LIVE_REGISTRY_CATALOG_URL"])
        print("LIVE_MUSIC_REGISTRY catalog=\(source.absoluteString) defaultSource=\(source == PluginRegistryModel.officialSource)")
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let client = PluginRegistryClient()
        let catalog = try await client.loadCatalog(from: source)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let specifications = [
            Specification(id: "com.dynamicisland.qq-music", name: "QQ 音乐", example: "qq-music",
                          bundle: "com.tencent.QQMusicMac"),
            Specification(id: "com.dynamicisland.spotify", name: "Spotify", example: "spotify",
                          bundle: "com.spotify.client")
        ]
        var packages: [String: ValidatedPluginPackage] = [:]
        for specification in specifications {
            let entry = try XCTUnwrap(catalog.entries.first { $0.id == specification.id }, "Missing published music source")
            XCTAssertEqual(entry.name, specification.name)
            XCTAssertEqual(entry.version.description, "0.1.0")
            XCTAssertEqual(entry.minHostVersion.description, "0.6.1")
            XCTAssertEqual(entry.source.absoluteString, "https://github.com/qyt1340272051-design/DynamicIsland")
            XCTAssertEqual(entry.download.absoluteString,
                "https://github.com/qyt1340272051-design/DynamicIsland/releases/download/plugins-music-0.1.0/\(specification.example)-0.1.0.dip")
            print("LIVE_MUSIC_REGISTRY package=\(entry.id) sha256=\(entry.hash)")

            // The production client downloads real anonymous HTTPS bytes;
            // Installer hashes that immutable buffer against entry.hash.
            let review = try await client.prepareDownload(entry, installer: fixture.installer)
            XCTAssertEqual(review.id, specification.id)
            XCTAssertEqual(Set(review.permissions), [.readMedia, .controlMedia])
            XCTAssertEqual(Set(review.capabilities), [.musicProvider])
            let beforeInstall = await fixture.manager.plugins()
            XCTAssertFalse(beforeInstall.contains { $0.id == specification.id }, "Preview cannot install or execute a plugin")
            XCTAssertFalse(fixture.registry.providers.contains { $0.id == specification.id })
            let record = try await fixture.installer.commit(review)
            XCTAssertFalse(record.isEnabled)
            XCTAssertEqual(record.regularFileCount, 5)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: record.canonicalRootURL.path)),
                           ["manifest.json", "index.js", "media-helper.js", "README.md", "LICENSE"])
            let packageValue = await fixture.manager.validatedPackage(id: record.id)
            let package = try XCTUnwrap(packageValue)
            packages[record.id] = package
            let descriptor = try XCTUnwrap(package.manifest.mediaProvider)
            let helper = try XCTUnwrap(package.mediaHelperSource)
            XCTAssertEqual(descriptor.targetBundleIdentifier, specification.bundle)
            XCTAssertEqual(OptionalMusicProviderRegistry.sha256(helper), descriptor.helperSHA256)
            XCTAssertEqual(OptionalMusicProviderRegistry.trustedHelpers[descriptor.helperSHA256], [specification.bundle])
            let localSource = repository.appendingPathComponent("docs/plugin-system/examples/\(specification.example)")
            XCTAssertEqual(helper, try Data(contentsOf: localSource.appendingPathComponent("media-helper.js")))
            XCTAssertEqual(package.entrySource, try Data(contentsOf: localSource.appendingPathComponent("index.js")))
            XCTAssertEqual(try Data(contentsOf: record.canonicalRootURL.appendingPathComponent("LICENSE")),
                           try Data(contentsOf: localSource.appendingPathComponent("LICENSE")))
            XCTAssertEqual(try fixture.permissions.snapshot(package: package).states,
                           [.readMedia: .requested, .controlMedia: .requested])

            _ = try await fixture.manager.enable(id: record.id)
            XCTAssertTrue(fixture.registry.providers.contains { $0.id == specification.id })
            XCTAssertEqual(try fixture.permissions.snapshot(package: package).states,
                           [.readMedia: .requested, .controlMedia: .requested], "Enable cannot approve media access")
        }
        XCTAssertEqual(fixture.registry.providers.count, 3)
        let callsBeforeGrants = await fixture.runner.argumentHistory()
        XCTAssertTrue(callsBeforeGrants.isEmpty, "Install and enable must not launch either helper")
        var expectedArguments: [[String]] = []
        for specification in specifications {
            let package = try XCTUnwrap(packages[specification.id])
            fixture.registry.selectedProviderID = specification.id
            await assertPermissionError(.notGranted) { try await fixture.router.nowPlaying() }
            let review = try fixture.permissions.snapshot(package: package).review
            try fixture.permissions.applyHostDecision(decision: .granted, review: review, permission: .readMedia)
            let info = try await fixture.router.nowPlaying()
            XCTAssertEqual(info.title, "Published music fixture")
            expectedArguments.append([specification.bundle, "nowPlaying"])
            await assertPermissionError(.notGranted) { try await fixture.router.togglePlayPause() }
            let afterReadOnly = await fixture.runner.argumentHistory()
            XCTAssertEqual(afterReadOnly, expectedArguments, "A read-only grant must not run a control")

            try fixture.permissions.applyHostDecision(decision: .granted, review: review, permission: .controlMedia)
            try await fixture.router.togglePlayPause()
            try await fixture.router.skipBackward()
            try await fixture.router.skipForward()
            let sought = try await fixture.router.seek(to: 30, trackIdentifier: "published-track")
            XCTAssertTrue(sought)
            expectedArguments += ["togglePlayPause", "skipBackward", "skipForward"].map { [specification.bundle, $0] }
            expectedArguments.append([specification.bundle, "seek", "30.0", "published-track"])
            let afterControls = await fixture.runner.argumentHistory()
            XCTAssertEqual(afterControls, expectedArguments, "Every operation must retain the selected fixed Bundle ID")

            try fixture.permissions.applyHostDecision(decision: .revoked, review: review, permission: .readMedia)
            await assertPermissionError(.revoked) { try await fixture.router.nowPlaying() }
            _ = try await fixture.manager.disable(id: specification.id)
            XCTAssertFalse(fixture.registry.providers.contains { $0.id == specification.id })
            await assertInactive { try await fixture.router.togglePlayPause() }
            _ = try await fixture.manager.uninstall(id: specification.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: package.canonicalRootURL.path))
            XCTAssertThrowsError(try fixture.permissions.snapshot(package: package))
            await assertInactive { try await fixture.router.nowPlaying() }
        }
        XCTAssertEqual(fixture.registry.providers.map(\.id), [OptionalMusicProviderRegistry.appleMusicID])
        let finalArguments = await fixture.runner.argumentHistory()
        XCTAssertEqual(finalArguments, expectedArguments)
        print("LIVE_MUSIC_REGISTRY verified=2 installedDisabled=true separateGrants=true fixedTargets=true realPlayback=false")
    }

    private func catalogSource(_ override: String?) throws -> URL {
        guard let override else { return PluginRegistryModel.officialSource }
        let url = try XCTUnwrap(URL(string: override))
        try PluginRegistryURLPolicy.catalog(url)
        let parts = url.path.split(separator: "/").map(String.init)
        guard Array(parts.prefix(2)) == ["qyt1340272051-design", "DynamicIsland"] else {
            throw PublishedMusicTestError.invalidRepository
        }
        return url
    }

    private func assertPermissionError<T>(_ expected: PluginPermissionError,
                                         _ operation: () async throws -> T) async {
        do { _ = try await operation(); XCTFail("Expected a media permission rejection") }
        catch { XCTAssertEqual(error as? PluginPermissionError, expected) }
    }

    private func assertInactive<T>(_ operation: () async throws -> T) async {
        do { _ = try await operation(); XCTFail("Stopped provider unexpectedly accepted an operation") }
        catch { XCTAssertEqual(error as? PluginMusicError, .inactiveProvider) }
    }

    private func makeFixture() async throws -> PublishedMusicFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PublishedMusicRegistry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let configuration = PluginManagerConfiguration(rootDirectoryURL: root.appendingPathComponent("managed"),
            hostVersion: try SemanticVersion("0.6.1"))
        let runner = PublishedMusicRunner()
        let registry = OptionalMusicProviderRegistry(runner: runner,
            trustedHelpers: OptionalMusicProviderRegistry.trustedHelpers)
        let permissions = PermissionManager()
        let activities = ActivityManager(configuration: .immediate)
        let bridge = PluginJSBridge(permissions: permissions)
        let lifecycle = PluginLifecycleBridge(activityManager: activities,
            actionRouter: ActionRouter(manager: activities), permissions: permissions,
            musicProviders: registry, runtimeFactory: { PluginRuntime(package: $0, bridge: bridge) })
        let manager = PluginManager(configuration: configuration, lifecycleHandler: lifecycle)
        let discovery = await manager.discover()
        XCTAssertTrue(discovery.failures.isEmpty)
        return PublishedMusicFixture(root: root, runner: runner, registry: registry, permissions: permissions,
            lifecycle: lifecycle, manager: manager,
            installer: PluginInstaller(manager: manager, configuration: configuration),
            router: MusicSourceRouter(registry: registry, fallback: PlaceholderMusicControlService()))
    }

    private struct Specification {
        let id: String
        let name: String
        let example: String
        let bundle: String
    }
}

@MainActor
private struct PublishedMusicFixture {
    let root: URL
    let runner: PublishedMusicRunner
    let registry: OptionalMusicProviderRegistry
    let permissions: PermissionManager
    let lifecycle: PluginLifecycleBridge
    let manager: PluginManager
    let installer: PluginInstaller
    let router: MusicSourceRouter

    func cleanup() { lifecycle.shutdown(); try? FileManager.default.removeItem(at: root) }
}

private actor PublishedMusicRunner: PluginMusicHelperRunning {
    private var arguments: [[String]] = []

    func run(source: String, arguments: [String], admission: PluginMusicHelperAdmission) async throws -> Data {
        try Task.checkCancellation()
        try admission.perform {}
        self.arguments.append(arguments)
        if arguments[1] == "nowPlaying" {
            return Data(#"{"isPlaying":true,"title":"Published music fixture","artist":"Fixture artist","album":"Fixture album","duration":120,"position":5,"trackIdentifier":"published-track"}"#.utf8)
        }
        return Data(#"{"ok":true}"#.utf8)
    }

    func argumentHistory() -> [[String]] { arguments }
}

private nonisolated enum PublishedMusicTestError: Error { case invalidRepository }
