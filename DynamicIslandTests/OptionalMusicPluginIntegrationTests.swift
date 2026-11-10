import Foundation
import XCTest
@testable import DynamicIsland

/// Exercises the optional package through the real archive installer, Manager,
/// permission gates, Runtime lifecycle, registry and music router. Only the
/// system-process runner is replaced; tests never control a real player.
@MainActor
final class OptionalMusicPluginIntegrationTests: XCTestCase {
    func testRealPackageInstallsDisabledAndRequiresSeparateMediaGrants() async throws {
        try await assertInstallAndMediaGrants(source: "netease-music")
    }

    func testQQMusicPackageInstallsDisabledAndRequiresSeparateMediaGrants() async throws {
        try await assertInstallAndMediaGrants(source: "qq-music")
    }

    func testSpotifyPackageInstallsDisabledAndRequiresSeparateMediaGrants() async throws {
        try await assertInstallAndMediaGrants(source: "spotify")
    }

    private func assertInstallAndMediaGrants(source: String) async throws {
        let fixture = try await makeFixture(sources: [source])
        defer { fixture.cleanup() }
        let review = try await fixture.installer.prepare(archiveURL: fixture.archive)
        XCTAssertEqual(Set(review.permissions), [.readMedia, .controlMedia])
        XCTAssertEqual(fixture.registry.providers.map(\.id), [OptionalMusicProviderRegistry.appleMusicID])
        let runnerValue1 = await fixture.runner.callCount()
        XCTAssertEqual(runnerValue1, 0)

        let record = try await fixture.installer.commit(review)
        XCTAssertFalse(record.isEnabled)
        let packageValue = await fixture.manager.validatedPackage(id: record.id)
        let package = try XCTUnwrap(packageValue)
        let permissions = fixture.permissions
        let snapshot = try permissions.snapshot(package: package)
        XCTAssertEqual(snapshot.states, [.readMedia: .requested, .controlMedia: .requested])
        XCTAssertEqual(package.mediaHelperSource, fixture.helper)
        XCTAssertEqual(fixture.registry.providers.count, 1)

        _ = try await fixture.manager.enable(id: record.id)
        XCTAssertTrue(fixture.lifecycle.allowsExecution(id: record.id))
        XCTAssertTrue(fixture.registry.providers.contains { $0.id == record.id })
        let runnerValue2 = await fixture.runner.callCount()
        XCTAssertEqual(runnerValue2, 0, "Enablement must not launch a media request.")
        fixture.registry.selectedProviderID = record.id
        let router = MusicSourceRouter(registry: fixture.registry, fallback: PlaceholderMusicControlService())
        await assertPermissionError(.notGranted) { try await router.nowPlaying() }
        let runnerValue3 = await fixture.runner.callCount()
        XCTAssertEqual(runnerValue3, 0)

        try permissions.applyHostDecision(decision: .granted, review: snapshot.review, permission: .readMedia)
        let info = try await router.nowPlaying()
        XCTAssertEqual(info.title, "Integration fixture")
        let runnerValue4 = await fixture.runner.operations()
        XCTAssertEqual(runnerValue4, ["nowPlaying"])
        try permissions.applyHostDecision(decision: .denied, review: snapshot.review, permission: .controlMedia)
        await assertPermissionError(.denied) { try await router.skipForward() }
        let runnerValue5 = await fixture.runner.operations()
        XCTAssertEqual(runnerValue5, ["nowPlaying"])

        try permissions.applyHostDecision(decision: .granted, review: snapshot.review, permission: .controlMedia)
        try await router.togglePlayPause()
        let runnerValue6 = await fixture.runner.operations()
        XCTAssertEqual(runnerValue6, ["nowPlaying", "togglePlayPause"])
        _ = try await fixture.manager.disable(id: record.id)
        XCTAssertFalse(fixture.registry.providers.contains { $0.id == record.id })
        await assertInactive { try await router.nowPlaying() }
        _ = try await fixture.manager.uninstall(id: record.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.canonicalRootURL.path))
        XCTAssertThrowsError(try permissions.snapshot(package: package))
        XCTAssertEqual(fixture.registry.providers.count, 1)
        await assertInactive { try await router.togglePlayPause() }
        let runnerValue7 = await fixture.runner.callCount()
        XCTAssertEqual(runnerValue7, 2)
    }

    func testDisableAndUninstallCancelAnInFlightOptionalMediaRequest() async throws {
        try await assertDisableAndUninstallCancelRequests(source: "netease-music")
    }

    func testQQMusicDisableAndUninstallCancelAnInFlightRequest() async throws {
        try await assertDisableAndUninstallCancelRequests(source: "qq-music")
    }

    func testSpotifyDisableAndUninstallCancelAnInFlightRequest() async throws {
        try await assertDisableAndUninstallCancelRequests(source: "spotify")
    }

    private func assertDisableAndUninstallCancelRequests(source: String) async throws {
        let fixture = try await makeFixture(sources: [source])
        defer { fixture.cleanup() }
        let installReview = try await fixture.installer.prepare(archiveURL: fixture.archive)
        let record = try await fixture.installer.commit(installReview)
        let packageValue = await fixture.manager.validatedPackage(id: record.id)
        let package = try XCTUnwrap(packageValue)
        let review = try fixture.permissions.snapshot(package: package).review
        for permission in [PluginPermission.readMedia, .controlMedia] {
            try fixture.permissions.applyHostDecision(decision: .granted, review: review, permission: permission)
        }
        _ = try await fixture.manager.enable(id: record.id)
        fixture.registry.selectedProviderID = record.id
        let router = MusicSourceRouter(registry: fixture.registry, fallback: PlaceholderMusicControlService())
        await fixture.runner.suspendNextRequest()
        let pending = Task { try await router.nowPlaying() }
        try await waitUntilSuspended(fixture.runner)
        _ = try await fixture.manager.disable(id: record.id)
        do { _ = try await pending.value; XCTFail("Disabled provider delivered a pending result.") }
        catch { XCTAssertTrue(error is CancellationError) }
        let runnerValue8 = await fixture.runner.cancellationCount()
        XCTAssertEqual(runnerValue8, 1)
        XCTAssertEqual(fixture.registry.providers.count, 1)

        _ = try await fixture.manager.enable(id: record.id)
        await fixture.runner.suspendNextRequest()
        let pendingUninstall = Task { try await router.nowPlaying() }
        try await waitUntilSuspended(fixture.runner)
        _ = try await fixture.manager.uninstall(id: record.id)
        do { _ = try await pendingUninstall.value; XCTFail("Uninstalled provider delivered a pending result.") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cancellations = await fixture.runner.cancellationCount()
        XCTAssertEqual(cancellations, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.canonicalRootURL.path))
        XCTAssertEqual(fixture.registry.providers.count, 1)
    }

    func testQQMusicAndSpotifyRouteAllOperationsToTheSelectedBundle() async throws {
        let fixture = try await makeFixture(sources: ["qq-music", "spotify"])
        defer { fixture.cleanup() }
        for source in ["qq-music", "spotify"] {
            let package = try XCTUnwrap(fixture.packages[source])
            let review = try await fixture.installer.prepare(archiveURL: package.archive)
            let record = try await fixture.installer.commit(review)
            let installedValue = await fixture.manager.validatedPackage(id: record.id)
            let installed = try XCTUnwrap(installedValue)
            let permissionReview = try fixture.permissions.snapshot(package: installed).review
            for permission in [PluginPermission.readMedia, .controlMedia] {
                try fixture.permissions.applyHostDecision(decision: .granted, review: permissionReview, permission: permission)
            }
            _ = try await fixture.manager.enable(id: record.id)
        }
        XCTAssertEqual(fixture.registry.providers.count, 3)
        let router = MusicSourceRouter(registry: fixture.registry, fallback: PlaceholderMusicControlService())
        var expectedArguments: [[String]] = []
        for source in ["qq-music", "spotify"] {
            let package = try XCTUnwrap(fixture.packages[source])
            fixture.registry.selectedProviderID = package.pluginID
            _ = try await router.nowPlaying()
            try await router.togglePlayPause()
            try await router.skipBackward()
            try await router.skipForward()
            let sought = try await router.seek(to: 30, trackIdentifier: "fixture-track")
            XCTAssertTrue(sought)
            expectedArguments += ["nowPlaying", "togglePlayPause", "skipBackward", "skipForward"].map {
                [package.targetBundleIdentifier, $0]
            }
            expectedArguments.append([package.targetBundleIdentifier, "seek", "30.0", "fixture-track"])
        }
        let actualArguments = await fixture.runner.argumentHistory()
        XCTAssertEqual(actualArguments, expectedArguments)

        let qq = try XCTUnwrap(fixture.packages["qq-music"])
        let spotify = try XCTUnwrap(fixture.packages["spotify"])
        fixture.registry.selectedProviderID = qq.pluginID
        await fixture.runner.suspendNextRequest()
        let pending = Task { try await router.nowPlaying() }
        try await waitUntilSuspended(fixture.runner)
        fixture.registry.selectedProviderID = spotify.pluginID
        do { _ = try await pending.value; XCTFail("A previous source delivered metadata after a source switch.") }
        catch { XCTAssertTrue(error is CancellationError || error as? PluginMusicError == .sourceChanged) }
        _ = try await router.nowPlaying()
        let finalArguments = await fixture.runner.argumentHistory()
        XCTAssertEqual(Array(finalArguments.suffix(2)), [
            [qq.targetBundleIdentifier, "nowPlaying"], [spotify.targetBundleIdentifier, "nowPlaying"]
        ])
        let cancellations = await fixture.runner.cancellationCount()
        XCTAssertEqual(cancellations, 1)
    }

    private func waitUntilSuspended(_ runner: IntegrationMediaRunner) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await runner.isSuspended()) {
            guard ContinuousClock.now < deadline else { throw IntegrationMediaTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func assertPermissionError<T>(_ expected: PluginPermissionError,
                                         _ operation: () async throws -> T) async {
        do { _ = try await operation(); XCTFail("Expected a media permission rejection.") }
        catch { XCTAssertEqual(error as? PluginPermissionError, expected) }
    }

    private func assertInactive<T>(_ operation: () async throws -> T) async {
        do { _ = try await operation(); XCTFail("Stopped provider unexpectedly accepted a call.") }
        catch { XCTAssertEqual(error as? PluginMusicError, .inactiveProvider) }
    }

    private func makeFixture(sources: [String]) async throws -> IntegrationMediaFixture {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OptionalMusicIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: NSNumber(value: 0o700)])
        var packages: [String: IntegrationMediaPackage] = [:]
        for sourceName in sources {
            let source = repo.appendingPathComponent("docs/plugin-system/examples/\(sourceName)")
            let files = try ["manifest.json", "index.js", "media-helper.js", "LICENSE"].map {
                ($0, try Data(contentsOf: source.appendingPathComponent($0)))
            }
            let manifest = try PluginManifest.decodeJSON(try XCTUnwrap(files.first?.1))
            let helper = try XCTUnwrap(files.first { $0.0 == "media-helper.js" }?.1)
            let descriptor = try XCTUnwrap(manifest.mediaProvider)
            XCTAssertEqual(OptionalMusicProviderRegistry.sha256(helper), descriptor.helperSHA256)
            XCTAssertTrue(OptionalMusicProviderRegistry.trustedHelpers[descriptor.helperSHA256]?
                .contains(descriptor.targetBundleIdentifier) == true, "Official package and Host trust pin must agree.")
            let archive = root.appendingPathComponent("\(sourceName).dip")
            try optionalMusicZIP(files).write(to: archive)
            packages[sourceName] = IntegrationMediaPackage(archive: archive, helper: helper,
                pluginID: manifest.id, targetBundleIdentifier: descriptor.targetBundleIdentifier)
        }
        let primary = try XCTUnwrap(sources.first.flatMap { packages[$0] })
        let configuration = PluginManagerConfiguration(rootDirectoryURL: root.appendingPathComponent("managed"),
            hostVersion: try SemanticVersion("0.6.1"))
        let runner = IntegrationMediaRunner()
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
        return IntegrationMediaFixture(root: root, archive: primary.archive, helper: primary.helper,
            packages: packages, runner: runner,
            registry: registry, permissions: permissions, lifecycle: lifecycle, manager: manager,
            installer: PluginInstaller(manager: manager, configuration: configuration))
    }
}

@MainActor
private struct IntegrationMediaFixture {
    let root: URL
    let archive: URL
    let helper: Data
    let packages: [String: IntegrationMediaPackage]
    let runner: IntegrationMediaRunner
    let registry: OptionalMusicProviderRegistry
    let permissions: PermissionManager
    let lifecycle: PluginLifecycleBridge
    let manager: PluginManager
    let installer: PluginInstaller
    func cleanup() { lifecycle.shutdown(); try? FileManager.default.removeItem(at: root) }
}

private nonisolated struct IntegrationMediaPackage {
    let archive: URL
    let helper: Data
    let pluginID: String
    let targetBundleIdentifier: String
}

private actor IntegrationMediaRunner: PluginMusicHelperRunning {
    private var calls: [String] = []
    private var arguments: [[String]] = []
    private var suspendNext = false
    private var suspended = false
    private var cancellations = 0

    func run(source: String, arguments: [String], admission: PluginMusicHelperAdmission) async throws -> Data {
        try Task.checkCancellation()
        try admission.perform {}
        calls.append(arguments[1])
        self.arguments.append(arguments)
        if suspendNext {
            suspendNext = false
            suspended = true
            defer { suspended = false }
            do { try await Task.sleep(for: .seconds(20)) }
            catch { cancellations += 1; throw error }
        }
        try Task.checkCancellation()
        try admission.perform {}
        if arguments[1] == "nowPlaying" {
            return Data(#"{"isPlaying":true,"title":"Integration fixture","artist":"Fixture artist","album":"Fixture album","duration":120,"position":5,"trackIdentifier":"fixture-track"}"#.utf8)
        }
        return Data(#"{"ok":true}"#.utf8)
    }
    func callCount() -> Int { calls.count }
    func operations() -> [String] { calls }
    func argumentHistory() -> [[String]] { arguments }
    func suspendNextRequest() { suspendNext = true }
    func isSuspended() -> Bool { suspended }
    func cancellationCount() -> Int { cancellations }
}

private nonisolated enum IntegrationMediaTestError: Error { case timedOut }

/// Stored ZIP built from real optional-package files, without subprocesses.
private nonisolated func optionalMusicZIP(_ files: [(String, Data)]) -> Data {
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
        data.mediaU32(0x04034b50); data.mediaU16(20); data.mediaU16(0x800); data.mediaU16(0); data.mediaU16(0); data.mediaU16(0)
        data.mediaU32(checksum); data.mediaU32(size); data.mediaU32(size); data.mediaU16(UInt16(name.count)); data.mediaU16(0)
        data.append(name); data.append(content)
        central.mediaU32(0x02014b50); central.mediaU16(0x0314); central.mediaU16(20); central.mediaU16(0x800); central.mediaU16(0)
        central.mediaU16(0); central.mediaU16(0); central.mediaU32(checksum); central.mediaU32(size); central.mediaU32(size)
        central.mediaU16(UInt16(name.count)); central.mediaU16(0); central.mediaU16(0); central.mediaU16(0); central.mediaU16(0)
        central.mediaU32(UInt32(0o100600) << 16); central.mediaU32(offset); central.append(name)
    }
    let centralOffset = UInt32(data.count)
    data.append(central)
    data.mediaU32(0x06054b50); data.mediaU16(0); data.mediaU16(0); data.mediaU16(UInt16(files.count)); data.mediaU16(UInt16(files.count))
    data.mediaU32(UInt32(central.count)); data.mediaU32(centralOffset); data.mediaU16(0)
    return data
}
private extension Data {
    mutating func mediaU16(_ value: UInt16) { append(contentsOf: [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]) }
    mutating func mediaU32(_ value: UInt32) { mediaU16(UInt16(truncatingIfNeeded: value)); mediaU16(UInt16(truncatingIfNeeded: value >> 16)) }
}
