import AppKit
import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginMusicControlServiceTests: XCTestCase {
    func testEnablementDoesNotRunHelperOrGrantPermissions() async throws {
        let fixture = try MusicProviderFixture()
        defer { fixture.shutdown() }
        XCTAssertEqual(fixture.registry.providers.map(\.id), [OptionalMusicProviderRegistry.appleMusicID, fixture.id])
        XCTAssertEqual(fixture.registry.selectedProviderID, OptionalMusicProviderRegistry.appleMusicID)
        await assertCalls(fixture, 0)
        fixture.registry.selectedProviderID = fixture.id
        do { _ = try await fixture.router.nowPlaying(); XCTFail("Missing explicit grant") }
        catch { XCTAssertEqual(error as? PluginPermissionError, .notGranted) }
        await assertCalls(fixture, 0)
    }

    func testReadGrantAllowsMetadataButControlRequiresSeparateGrant() async throws {
        let fixture = try MusicProviderFixture()
        defer { fixture.shutdown() }
        fixture.registry.selectedProviderID = fixture.id
        try fixture.grant(.readMedia)
        let info = try await fixture.router.nowPlaying()
        XCTAssertEqual(info.title, "Test track")
        XCTAssertEqual(info.trackIdentifier, "track-1")
        do { try await fixture.router.skipForward(); XCTFail("Control must require a second permission") }
        catch { XCTAssertEqual(error as? PluginPermissionError, .notGranted) }
        await assertCalls(fixture, 1)
        try fixture.grant(.controlMedia)
        await fixture.runner.respond(with: Data("{\"ok\":true}".utf8))
        try await fixture.router.skipForward()
        let arguments = await fixture.runner.lastArguments()
        XCTAssertEqual(arguments, ["com.netease.163music", "skipForward"])
        await assertFallbackActions(fixture, 0)
    }

    func testDisabledSelectedProviderNeverControlsAppleMusic() async throws {
        let fixture = try MusicProviderFixture()
        defer { fixture.shutdown() }
        fixture.registry.selectedProviderID = fixture.id
        try fixture.grant(.readMedia)
        try fixture.grant(.controlMedia)
        fixture.bridge.pluginDidChangeEnablement(id: fixture.id, isEnabled: false)
        XCTAssertEqual(fixture.registry.selectedProviderID, fixture.id)
        XCTAssertEqual(fixture.registry.providers.map(\.id), [OptionalMusicProviderRegistry.appleMusicID])
        do { try await fixture.router.togglePlayPause(); XCTFail("An absent selected source must fail closed") }
        catch { XCTAssertEqual(error as? PluginMusicError, .inactiveProvider) }
        await assertFallbackActions(fixture, 0)
        await assertCalls(fixture, 0)
    }

    func testPermissionRevocationCancelsInflightReadAndRegrantCannotDeliverOldData() async throws {
        let fixture = try MusicProviderFixture()
        defer { fixture.shutdown() }
        fixture.registry.selectedProviderID = fixture.id
        try fixture.grant(.readMedia)
        await fixture.runner.setSuspended(true)
        let request = Task { try await fixture.router.nowPlaying() }
        try await waitUntil { await fixture.runner.count() == 1 }
        try fixture.permissions.applyHostDecision(decision: .revoked, review: fixture.review, permission: .readMedia)
        try fixture.grant(.readMedia)
        do { _ = try await request.value; XCTFail("Old request survived revocation") }
        catch { XCTAssertTrue(error is CancellationError || error is PluginPermissionError) }
        let cancellations = await fixture.runner.cancellations()
        XCTAssertEqual(cancellations, 1)
    }

    func testLifecycleStopCancelsInflightRequest() async throws {
        let fixture = try MusicProviderFixture()
        defer { fixture.shutdown() }
        fixture.registry.selectedProviderID = fixture.id
        try fixture.grant(.readMedia)
        await fixture.runner.setSuspended(true)
        let request = Task { try await fixture.router.nowPlaying() }
        try await waitUntil { await fixture.runner.count() == 1 }
        fixture.bridge.pluginWillUnload(id: fixture.id)
        do { _ = try await request.value; XCTFail("A stopped runtime delivered metadata") }
        catch { XCTAssertTrue(error is CancellationError || error is PluginExecutionError) }
        let cancellations = await fixture.runner.cancellations()
        XCTAssertEqual(cancellations, 1)
    }

    func testSourceSwitchCancelsPendingMetadataAndDoesNotRetargetOperation() async throws {
        let fixture = try MusicProviderFixture()
        defer { fixture.shutdown() }
        fixture.registry.selectedProviderID = fixture.id
        try fixture.grant(.readMedia)
        await fixture.runner.setSuspended(true)
        let request = Task { try await fixture.router.nowPlaying() }
        try await waitUntil { await fixture.runner.count() == 1 }
        fixture.registry.selectedProviderID = OptionalMusicProviderRegistry.appleMusicID
        do { _ = try await request.value; XCTFail("A superseded source delivered metadata") }
        catch { XCTAssertTrue(error is CancellationError || error as? PluginMusicError == .sourceChanged) }
        await assertFallbackActions(fixture, 0)
    }

    func testUnrelatedPluginChangesDoNotInvalidateOrCancelSelectedMusicSource() async throws {
        let fixture = try MusicProviderFixture()
        defer { fixture.shutdown() }
        fixture.registry.selectedProviderID = fixture.id
        try fixture.grant(.readMedia)
        await fixture.runner.setSuspended(true)
        let request = Task { try await fixture.router.nowPlaying() }
        try await waitUntil { await fixture.runner.count() == 1 }
        let generation = fixture.registry.generation
        let manifest = try PluginManifest(id: "com.example.unrelated", name: "Unrelated", version: SemanticVersion("1.0.0"),
            engine: .javaScriptCore, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"),
            permissions: [.localStorage], capabilities: [.localStorage])
        let package = ValidatedPluginPackage(manifest: manifest,
            canonicalRootURL: URL(fileURLWithPath: "/tmp/unrelated-music-fixture"), entryRelativePath: "index.js",
            entrySource: Data("function onStart() {}".utf8), regularFileCount: 2, totalFileBytes: 20)
        let review = fixture.permissions.request(package: package)
        try fixture.permissions.applyHostDecision(decision: .granted, review: review, permission: .localStorage)
        fixture.bridge.pluginDidLoad(package, isEnabled: false)
        fixture.bridge.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: false)
        fixture.registry.deactivate(pluginID: package.manifest.id)
        XCTAssertEqual(fixture.registry.generation, generation)
        let cancellations = await fixture.runner.cancellations()
        XCTAssertEqual(cancellations, 0)
        request.cancel()
        do { _ = try await request.value; XCTFail("Caller cancellation was ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testUntrustedOrChangedHelperFailsBeforeLaunching() async throws {
        let fixture = try MusicProviderFixture()
        defer { fixture.shutdown() }
        let replacement = ValidatedPluginPackage(manifest: fixture.package.manifest,
            canonicalRootURL: fixture.package.canonicalRootURL, entryRelativePath: "index.js",
            entrySource: fixture.package.entrySource, regularFileCount: 3, totalFileBytes: 50,
            mediaHelperSource: Data("changed-helper".utf8))
        XCTAssertThrowsError(try fixture.registry.activate(package: replacement, context: fixture.runtime.context!,
                                                          permissions: fixture.permissions)) {
            XCTAssertEqual($0 as? PluginMusicError, .untrustedHelper)
        }
        let unrelated = OptionalMusicProviderRegistry(runner: fixture.runner, trustedHelpers: [:])
        XCTAssertThrowsError(try unrelated.activate(package: fixture.package, context: fixture.runtime.context!,
                                                   permissions: fixture.permissions)) {
            XCTAssertEqual($0 as? PluginMusicError, .untrustedHelper)
        }
        await assertCalls(fixture, 0)
    }

    func testSeekCarriesTrackIdentityAndRejectsInvalidArgumentsWithoutLaunch() async throws {
        let fixture = try MusicProviderFixture()
        defer { fixture.shutdown() }
        fixture.registry.selectedProviderID = fixture.id
        try fixture.grant(.readMedia)
        try fixture.grant(.controlMedia)
        for position in [Double.nan, Double.infinity, -1] {
            let result = try await fixture.router.seek(to: position, trackIdentifier: "track-1")
            XCTAssertFalse(result)
        }
        let emptyIdentifier = try await fixture.router.seek(to: 10, trackIdentifier: "")
        XCTAssertFalse(emptyIdentifier)
        await assertCalls(fixture, 0)
        await fixture.runner.respond(with: Data("{\"ok\":false}".utf8))
        let staleTrack = try await fixture.router.seek(to: 20, trackIdentifier: "old-track")
        XCTAssertFalse(staleTrack)
        let arguments = await fixture.runner.lastArguments()
        XCTAssertEqual(arguments, ["com.netease.163music", "seek", "20.0", "old-track"])
    }

    func testMalformedMetadataAndArtworkFailClosed() throws {
        for response in ["{}", "{\"error\":\"private content must not escape\"}",
                         "{\"isPlaying\":true,\"title\":\"x\",\"artist\":\"a\",\"album\":\"b\",\"duration\":2,\"position\":1,\"trackIdentifier\":\"1\",\"artworkBase64\":\"bm90LWFuLWltYWdl\"}"] {
            XCTAssertThrowsError(try MusicSourceRouter.parseNowPlaying(Data(response.utf8)))
        }
        XCTAssertThrowsError(try MusicSourceRouter.parseControl(Data("{}".utf8)))
        XCTAssertFalse(try MusicSourceRouter.parseControl(Data("{\"ok\":false}".utf8)))
    }

    func testArtworkSurvivesStateUUIDChangeAndTransientMissingCallback() async throws {
        let fixture = try MusicProviderFixture()
        defer { fixture.shutdown() }
        fixture.registry.selectedProviderID = fixture.id
        try fixture.grant(.readMedia)
        let artwork = try artworkPNG()
        await fixture.runner.respond(with: try metadata(track: "session-uuid-1", artwork: artwork,
                                                        duration: 100.00004, isPlaying: true))
        let playing = try await fixture.router.nowPlaying()
        XCTAssertEqual(playing.artworkData, artwork)
        await fixture.runner.respond(with: try metadata(track: "session-uuid-2", duration: 100.00001, isPlaying: false))
        let paused = try await fixture.router.nowPlaying()
        XCTAssertEqual(paused.artworkData, artwork)
        XCTAssertEqual(paused.trackIdentifier, "session-uuid-2", "Artwork caching must not replace transport identity")
        XCTAssertFalse(paused.isPlaying)
        XCTAssertEqual(fixture.router.artworkCacheStatistics.count, 1)
    }

    func testDifferentTrackDoesNotBorrowArtworkAndPreviousTrackCanRecoverItsOwnCover() async throws {
        let fixture = try MusicProviderFixture()
        defer { fixture.shutdown() }
        fixture.registry.selectedProviderID = fixture.id
        try fixture.grant(.readMedia)
        let artwork = try artworkPNG()
        await fixture.runner.respond(with: try metadata(title: "First", artwork: artwork))
        _ = try await fixture.router.nowPlaying()
        await fixture.runner.respond(with: try metadata(title: "Second", track: "second"))
        let second = try await fixture.router.nowPlaying()
        XCTAssertNil(second.artworkData)
        await fixture.runner.respond(with: try metadata(title: "First", track: "first-new-uuid"))
        let previous = try await fixture.router.nowPlaying()
        XCTAssertEqual(previous.artworkData, artwork)
    }

    func testArtworkCacheEvictsLeastRecentlyUsedTracksAtCountLimit() async throws {
        let fixture = try MusicProviderFixture()
        defer { fixture.shutdown() }
        fixture.registry.selectedProviderID = fixture.id
        try fixture.grant(.readMedia)
        let artwork = try artworkPNG()
        for index in 0..<8 {
            await fixture.runner.respond(with: try metadata(title: "Track \(index)", artwork: artwork))
            _ = try await fixture.router.nowPlaying()
        }
        // A cache hit is a use and must protect track zero from the next eviction.
        await fixture.runner.respond(with: try metadata(title: "Track 0"))
        _ = try await fixture.router.nowPlaying()
        await fixture.runner.respond(with: try metadata(title: "Track 8", artwork: artwork))
        _ = try await fixture.router.nowPlaying()
        XCTAssertEqual(fixture.router.artworkCacheStatistics.count, 8)
        await fixture.runner.respond(with: try metadata(title: "Track 1"))
        let evicted = try await fixture.router.nowPlaying()
        XCTAssertNil(evicted.artworkData)
        await fixture.runner.respond(with: try metadata(title: "Track 0"))
        let retained = try await fixture.router.nowPlaying()
        XCTAssertEqual(retained.artworkData, artwork)
    }

    func testArtworkCacheEnforcesAggregateEightMiBByteLimit() async throws {
        let fixture = try MusicProviderFixture()
        defer { fixture.shutdown() }
        fixture.registry.selectedProviderID = fixture.id
        try fixture.grant(.readMedia)
        let artwork = try artworkPNG(paddedTo: 2 * 1_024 * 1_024)
        XCTAssertEqual(AppleMusicControlService.validatedArtworkData(artwork), artwork)
        for index in 0..<5 {
            await fixture.runner.respond(with: try metadata(title: "Large \(index)", artwork: artwork))
            _ = try await fixture.router.nowPlaying()
            XCTAssertLessThanOrEqual(fixture.router.artworkCacheStatistics.bytes, 8 * 1_024 * 1_024)
        }
        XCTAssertEqual(fixture.router.artworkCacheStatistics.count, 4)
        await fixture.runner.respond(with: try metadata(title: "Large 0"))
        let evicted = try await fixture.router.nowPlaying()
        XCTAssertNil(evicted.artworkData)
    }

    func testArtworkCacheClearsImmediatelyOnPermissionRevocationAndSourceStop() async throws {
        let fixture = try MusicProviderFixture()
        defer { fixture.shutdown() }
        fixture.registry.selectedProviderID = fixture.id
        try fixture.grant(.readMedia)
        await fixture.runner.respond(with: try metadata(artwork: artworkPNG()))
        _ = try await fixture.router.nowPlaying()
        XCTAssertEqual(fixture.router.artworkCacheStatistics.count, 1)
        try fixture.permissions.applyHostDecision(decision: .revoked, review: fixture.review, permission: .readMedia)
        XCTAssertEqual(fixture.router.artworkCacheStatistics.count, 0)
        XCTAssertEqual(fixture.router.artworkCacheStatistics.bytes, 0)
        try fixture.grant(.readMedia)
        await fixture.runner.respond(with: try metadata())
        let afterRegrant = try await fixture.router.nowPlaying()
        XCTAssertNil(afterRegrant.artworkData)
        await fixture.runner.respond(with: try metadata(artwork: artworkPNG()))
        _ = try await fixture.router.nowPlaying()
        fixture.bridge.pluginDidChangeEnablement(id: fixture.id, isEnabled: false)
        XCTAssertEqual(fixture.router.artworkCacheStatistics.count, 0)
        XCTAssertEqual(fixture.router.artworkCacheStatistics.bytes, 0)
    }

    func testRevokingOnlyPlaybackControlRetainsPermittedReadOnlyArtwork() async throws {
        let fixture = try MusicProviderFixture()
        defer { fixture.shutdown() }
        fixture.registry.selectedProviderID = fixture.id
        try fixture.grant(.readMedia)
        try fixture.grant(.controlMedia)
        let artwork = try artworkPNG()
        await fixture.runner.respond(with: try metadata(artwork: artwork))
        _ = try await fixture.router.nowPlaying()
        let artworkGeneration = fixture.registry.artworkGeneration
        try fixture.permissions.applyHostDecision(decision: .revoked, review: fixture.review, permission: .controlMedia)
        XCTAssertEqual(fixture.registry.artworkGeneration, artworkGeneration)
        XCTAssertEqual(fixture.router.artworkCacheStatistics.count, 1)
        await fixture.runner.respond(with: try metadata(track: "new-session-uuid"))
        let readOnly = try await fixture.router.nowPlaying()
        XCTAssertEqual(readOnly.title, "Test track")
        XCTAssertEqual(readOnly.artworkData, artwork)
        do { try await fixture.router.togglePlayPause(); XCTFail("Revoked playback control was allowed") }
        catch { XCTAssertEqual(error as? PluginPermissionError, .revoked) }
        await assertFallbackActions(fixture, 0)
    }

    func testShutdownPreservesExplicitPreferenceWithoutLeavingOptionalWork() throws {
        let fixture = try MusicProviderFixture()
        fixture.registry.selectedProviderID = fixture.id
        fixture.shutdown()
        XCTAssertEqual(fixture.registry.selectedProviderID, fixture.id)
        XCTAssertEqual(fixture.registry.providers.map(\.id), [OptionalMusicProviderRegistry.appleMusicID])
    }

    func testAutomaticModeIgnoresTheLegacySavedManualSource() throws {
        let name = "DynamicIsland.PluginMusicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("com.example.optional-music", forKey: "music.selectedProviderID")
        let registry = OptionalMusicProviderRegistry(defaults: defaults)
        XCTAssertEqual(registry.selectedProviderID, OptionalMusicProviderRegistry.noActiveSourceID)
        registry.shutdown()
        let restored = OptionalMusicProviderRegistry(defaults: defaults)
        XCTAssertEqual(restored.selectedProviderID, OptionalMusicProviderRegistry.noActiveSourceID)
        XCTAssertEqual(restored.sourceStatus, .detecting)
        XCTAssertEqual(restored.providers.map(\.id), [OptionalMusicProviderRegistry.appleMusicID])
    }

    func testSystemRunnerRunsDataOnlyArgumentsWithoutShellAndRejectsRevokedAdmission() async throws {
        let admission = PluginMusicHelperAdmission(lifecycle: PluginResourceAdmission(), read: nil, control: nil)
        let runner = SystemMusicHelperRunner()
        let bytes = try await runner.run(source: "function run(argv) { return JSON.stringify(argv); }",
                                         arguments: ["literal;$(not-a-command)", "quotes\""], admission: admission)
        let arguments = try JSONDecoder().decode([String].self, from: bytes)
        XCTAssertEqual(arguments, ["literal;$(not-a-command)", "quotes\""])
        admission.lifecycle.revoke()
        do {
            _ = try await runner.run(source: "function run() { return 'must-not-run'; }", arguments: [], admission: admission)
            XCTFail("Revoked lifecycle launched a subprocess")
        } catch { XCTAssertEqual(error as? PluginResourceError, .inactiveExecution) }
    }

    func testSystemRunnerBoundsOutputAndDeadline() async throws {
        let admission = PluginMusicHelperAdmission(lifecycle: PluginResourceAdmission(), read: nil, control: nil)
        do {
            _ = try await SystemMusicHelperRunner(outputLimit: 32).run(
                source: "function run() { return 'x'.repeat(10000); }", arguments: [], admission: admission)
            XCTFail("Unbounded helper output was accepted")
        } catch { XCTAssertEqual(error as? PluginMusicError, .invalidResponse) }
        do {
            _ = try await SystemMusicHelperRunner(timeout: 0.2).run(
                source: "function run() { while (true) {} }", arguments: [], admission: admission)
            XCTFail("Hung helper did not time out")
        } catch { XCTAssertEqual(error as? PluginMusicError, .timedOut) }
    }

    func testSystemRunnerMetadataDeadlineRecoversBeforeTransportBudgetExpires() async throws {
        let admission = PluginMusicHelperAdmission(lifecycle: PluginResourceAdmission(), read: nil, control: nil)
        // This fixture only sleeps in its own subprocess; it never imports
        // MediaRemote or sends a command to any installed player.
        let delayedSnapshot = """
            ObjC.import('Foundation');
            function run() {
                $.NSThread.sleepForTimeInterval(2.25);
                return 'completed';
            }
            """
        do {
            _ = try await SystemMusicHelperRunner().run(source: delayedSnapshot,
                arguments: ["com.example.fixture", "nowPlaying"], admission: admission)
            XCTFail("A slow metadata read used the longer transport deadline")
        } catch { XCTAssertEqual(error as? PluginMusicError, .timedOut) }
        let command = try await SystemMusicHelperRunner().run(source: delayedSnapshot,
            arguments: ["com.example.fixture", "skipForward"], admission: admission)
        XCTAssertEqual(String(data: command, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), "completed")
    }

    func testExplicitSystemRunnerDeadlineOverridesBothOperationBudgets() async throws {
        let admission = PluginMusicHelperAdmission(lifecycle: PluginResourceAdmission(), read: nil, control: nil)
        let source = """
            ObjC.import('Foundation');
            function run() {
                $.NSThread.sleepForTimeInterval(2.25);
                return 'completed';
            }
            """
        // An explicit larger test/diagnostic budget must not be silently
        // clamped to the normal two-second metadata deadline.
        let metadata = try await SystemMusicHelperRunner(timeout: 3).run(source: source,
            arguments: ["com.example.fixture", "nowPlaying"], admission: admission)
        XCTAssertEqual(String(data: metadata, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), "completed")
        for operation in ["nowPlaying", "seek"] {
            do {
                _ = try await SystemMusicHelperRunner(timeout: 0.15).run(source: source,
                    arguments: ["com.example.fixture", operation], admission: admission)
                XCTFail("Explicit deadline was ignored for \(operation)")
            } catch { XCTAssertEqual(error as? PluginMusicError, .timedOut) }
        }
    }

    func testSystemRunnerCallerCancellationStopsPendingProcess() async throws {
        let admission = PluginMusicHelperAdmission(lifecycle: PluginResourceAdmission(), read: nil, control: nil)
        let runner = SystemMusicHelperRunner()
        let task = Task {
            try await runner.run(source: "function run() { while (true) {} }", arguments: [], admission: admission)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("A cancelled helper delivered output") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testSystemRunnerChecksPermissionAtActualLaunch() async throws {
        let fixture = try MusicProviderFixture()
        defer { fixture.shutdown() }
        try fixture.grant(.readMedia)
        let lease = try fixture.permissions.require(permission: .readMedia, package: fixture.package)
        let admission = PluginMusicHelperAdmission(lifecycle: fixture.runtime.context!.resourceAdmission,
                                                   read: lease, control: nil)
        try fixture.permissions.applyHostDecision(decision: .revoked, review: fixture.review, permission: .readMedia)
        do {
            _ = try await SystemMusicHelperRunner().run(source: "function run() { return 'must-not-run'; }",
                                                        arguments: [], admission: admission)
            XCTFail("A revoked permission launched the process")
        } catch { XCTAssertEqual(error as? PluginPermissionError, .revoked) }
    }

    func testSystemRunnerMediaQueriesCompleteInsideSandboxedTestHost() async throws {
        // Exercise MediaRemote from the actual sandboxed App-hosted XCTest
        // process, rather than accepting a successful Terminal-only probe.
        // Force the query branch without launching a player, and replace the
        // metadata conversion with callback booleans so no titles are recorded.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("docs/plugin-system/examples/netease-music/media-helper.js")
        let original = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(OptionalMusicProviderRegistry.sha256(Data(original.utf8)),
                       "37c306a675aa34419a34bc03a412a934953f2b5243c96ee3f9855d5b537a9d32")
        let runningPattern = #"(?s)function running\(\) \{\s*return Number\(\$\.NSRunningApplication\.runningApplicationsWithBundleIdentifier\(target\)\.count\) > 0;\s*\}"#
        let regex = try NSRegularExpression(pattern: runningPattern)
        let range = NSRange(original.startIndex..<original.endIndex, in: original)
        XCTAssertEqual(regex.numberOfMatches(in: original, range: range), 1)
        var diagnostic = regex.stringByReplacingMatches(in: original, range: range,
                                                         withTemplate: "function running() { return true; }")
        let artworkMarker = "state.artwork = value;"
        XCTAssertEqual(diagnostic.components(separatedBy: artworkMarker).count, 2)
        diagnostic = diagnostic.replacingOccurrences(of: artworkMarker,
            with: "state.artwork = value; state.artCallback = true; state.artError = present(_);")
        let metadataMarker = "if (!state.infoDone || !state.playingDone) reject('queryTimedOut');"
        XCTAssertEqual(diagnostic.components(separatedBy: metadataMarker).count, 2)
        diagnostic = diagnostic.replacingOccurrences(of: metadataMarker, with: """
            var activePath = Request.localNowPlayingPlayerPath;
            return {diagnostic: true, infoDone: state.infoDone, playingDone: state.playingDone,
                    artDone: state.artDone, artCallback: !!state.artCallback,
                    queryError: state.error, artError: !!state.artError,
                    hasSession: present(activePath) && present(activePath.client)};
            """)
        let admission = PluginMusicHelperAdmission(lifecycle: PluginResourceAdmission(), read: nil, control: nil)
        let data = try await SystemMusicHelperRunner(timeout: 3).run(source: diagnostic,
            arguments: ["com.netease.163music", "nowPlaying"], admission: admission)
        let flags = try JSONDecoder().decode([String: Bool].self, from: data)
        XCTAssertEqual(flags["diagnostic"], true)
        XCTAssertEqual(flags["infoDone"], true)
        XCTAssertEqual(flags["playingDone"], true)
        XCTAssertEqual(flags["artDone"], true)
        XCTAssertEqual(flags["artCallback"], true)
        // Callbacks must still complete without a media session, as on a
        // headless runner, but MediaRemote may then report an error.
        if flags["hasSession"] == true {
            XCTAssertEqual(flags["queryError"], false)
            XCTAssertEqual(flags["artError"], false)
        }
    }

    private func assertCalls(_ fixture: MusicProviderFixture, _ expected: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let calls = await fixture.runner.count()
        XCTAssertEqual(calls, expected, file: file, line: line)
    }

    private func metadata(title: String = "Test track", track: String = "track-1", artwork: Data? = nil,
                          duration: Double = 100, isPlaying: Bool = true) throws -> Data {
        var object: [String: Any] = ["isPlaying": isPlaying, "title": title, "artist": "Artist", "album": "Album",
                                     "duration": duration, "position": 20, "trackIdentifier": track]
        if let artwork { object["artworkBase64"] = artwork.base64EncodedString() }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func artworkPNG(paddedTo byteCount: Int = 0) throws -> Data {
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        image.bitmapData?.initialize(repeating: 255, count: image.bytesPerRow * image.pixelsHigh)
        var data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        if byteCount > data.count { data.append(Data(repeating: 0, count: byteCount - data.count)) }
        return data
    }

    private func assertFallbackActions(_ fixture: MusicProviderFixture, _ expected: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let count = await fixture.fallback.actions()
        XCTAssertEqual(count, expected, file: file, line: line)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw PluginMusicError.timedOut
    }
}

@MainActor
private final class MusicProviderFixture {
    let id = "com.example.optional-music"
    let runner = MusicHelperRunnerDouble()
    let fallback = MusicFallbackDouble()
    let permissions = PermissionManager()
    let runtime = MusicProviderRuntimeDouble()
    let package: ValidatedPluginPackage
    let review: PluginPermissionReview
    let registry: OptionalMusicProviderRegistry
    let router: MusicSourceRouter
    let bridge: PluginLifecycleBridge

    init() throws {
        let helper = Data("fixture-helper".utf8)
        let digest = OptionalMusicProviderRegistry.sha256(helper)
        let descriptor = PluginMediaProviderDescriptor(targetBundleIdentifier: "com.netease.163music",
            displayName: "网易云音乐", helperPath: "media-helper.js", helperSHA256: digest)
        let manifest = try PluginManifest(id: id, name: "Optional Music", version: SemanticVersion("1.0.0"),
            engine: .javaScriptCore, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.1"),
            permissions: [.readMedia, .controlMedia], capabilities: [.musicProvider], mediaProvider: descriptor)
        package = ValidatedPluginPackage(manifest: manifest, canonicalRootURL: URL(fileURLWithPath: "/tmp/music-fixture"),
            entryRelativePath: "index.js", entrySource: Data("function onStart() {}".utf8),
            regularFileCount: 3, totalFileBytes: 50, mediaHelperSource: helper)
        review = permissions.request(package: package)
        registry = OptionalMusicProviderRegistry(runner: runner, trustedHelpers: [digest: ["com.netease.163music"]])
        router = MusicSourceRouter(registry: registry, fallback: fallback)
        let manager = ActivityManager()
        let runtime = self.runtime
        bridge = PluginLifecycleBridge(activityManager: manager, actionRouter: ActionRouter(manager: manager),
                                       permissions: permissions, musicProviders: registry, runtimeFactory: { _ in runtime })
        bridge.pluginDidLoad(package, isEnabled: true)
    }

    func grant(_ permission: PluginPermission) throws {
        try permissions.applyHostDecision(decision: .granted, review: review, permission: permission)
    }

    func shutdown() { bridge.shutdown(); registry.shutdown() }
}

@MainActor
private final class MusicProviderRuntimeDouble: PluginLifecycleRuntime {
    var context: PluginExecutionContext?
    func onStart(context: PluginExecutionContext) throws { self.context = context }
    func onStop(reason: PluginStopReason) throws {}
    func teardown() {}
}

private actor MusicHelperRunnerDouble: PluginMusicHelperRunning {
    private var calls: [[String]] = []
    private var cancelled = 0
    private var suspended = false
    private var response = Data("{\"isPlaying\":true,\"title\":\"Test track\",\"artist\":\"Artist\",\"album\":\"Album\",\"duration\":100,\"position\":20,\"trackIdentifier\":\"track-1\"}".utf8)

    func run(source: String, arguments: [String], admission: PluginMusicHelperAdmission) async throws -> Data {
        try admission.perform {}
        calls.append(arguments)
        if suspended {
            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
            catch { cancelled += 1; throw error }
        }
        try Task.checkCancellation()
        return response
    }

    func count() -> Int { calls.count }
    func cancellations() -> Int { cancelled }
    func lastArguments() -> [String]? { calls.last }
    func setSuspended(_ value: Bool) { suspended = value }
    func respond(with data: Data) { response = data }
}

private actor MusicFallbackDouble: MusicControlService {
    private var actionCount = 0
    func togglePlayPause() { actionCount += 1 }
    func skipBackward() { actionCount += 1 }
    func skipForward() { actionCount += 1 }
    func seek(to position: TimeInterval, trackIdentifier: String) -> Bool { actionCount += 1; return true }
    func nowPlaying() -> NowPlayingInfo { .empty }
    func actions() -> Int { actionCount }
}
