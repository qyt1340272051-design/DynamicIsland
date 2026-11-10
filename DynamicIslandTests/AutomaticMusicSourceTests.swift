import Combine
import Foundation
import XCTest
@testable import DynamicIsland

/// Uses synthetic packages and a data-only helper double. No test queries the
/// system player, requests Automation access, or changes real playback.
@MainActor
final class AutomaticMusicSourceTests: XCTestCase {
    func testFollowsTheSystemSourceInsteadOfThePreviousManualChoice() async throws {
        let fixture = try AutomaticMusicFixture()
        defer { fixture.shutdown() }
        try fixture.grantBoth(.readMedia)
        fixture.registry.selectedProviderID = AutomaticMusicFixture.qqID

        for (bundle, provider, title, name) in [
            (AutomaticMusicFixture.appleBundle, OptionalMusicProviderRegistry.appleMusicID, "Apple Music song", "Apple Music"),
            (AutomaticMusicFixture.spotifyBundle, AutomaticMusicFixture.spotifyID, AutomaticMusicFixture.spotifyBundle + " song", "Spotify"),
            (AutomaticMusicFixture.qqBundle, AutomaticMusicFixture.qqID, AutomaticMusicFixture.qqBundle + " song", "QQ 音乐")
        ] {
            await fixture.detector.set(.source(bundleIdentifier: bundle))
            let info = try await fixture.router.nowPlaying()
            XCTAssertEqual(info.title, title)
            XCTAssertEqual(fixture.registry.selectedProviderID, provider)
            XCTAssertEqual(fixture.registry.sourceStatus, .active(name))
            XCTAssertFalse(info.trackIdentifier.isEmpty)
            XCTAssertNotEqual(info.trackIdentifier, "shared-track", "A displayed seek identity must include its source.")
        }
        let helperHistory = await fixture.runner.history()
        XCTAssertEqual(helperHistory, [
            [AutomaticMusicFixture.spotifyBundle, "nowPlaying"],
            [AutomaticMusicFixture.qqBundle, "nowPlaying"]
        ])
        let fallbackReads = await fixture.fallback.reads()
        XCTAssertEqual(fallbackReads, 1)
    }

    func testNoActiveSourceDoesNotReadAppleMusicOrLaunchAnyPlugin() async throws {
        let fixture = try AutomaticMusicFixture()
        defer { fixture.shutdown() }
        try fixture.grantBoth(.readMedia)
        let info = try await fixture.router.nowPlaying()
        XCTAssertEqual(info, .empty)
        XCTAssertEqual(fixture.registry.sourceStatus, .idle)
        await assertNoPlaybackCalls(fixture)
        await assertControlRejected { try await fixture.router.togglePlayPause() }
        await assertNoPlaybackCalls(fixture)
    }

    func testUnsupportedActivePlayerDoesNotFallBackToAnInstalledPlayer() async throws {
        let fixture = try AutomaticMusicFixture()
        defer { fixture.shutdown() }
        try fixture.grantBoth(.readMedia)
        try fixture.grantBoth(.controlMedia)
        await fixture.detector.set(.unsupported)
        let info = try await fixture.router.nowPlaying()
        XCTAssertEqual(info, .empty)
        XCTAssertEqual(fixture.registry.sourceStatus, .unsupported)
        await assertControlRejected { try await fixture.router.skipForward() }
        await assertNoPlaybackCalls(fixture)
    }

    func testControlGrantAloneCannotReadOrSelectTheActiveOptionalPlayer() async throws {
        let fixture = try AutomaticMusicFixture()
        defer { fixture.shutdown() }
        try fixture.grant(.controlMedia, provider: AutomaticMusicFixture.qqID)
        try fixture.grant(.readMedia, provider: AutomaticMusicFixture.spotifyID)
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.qqBundle))
        let unavailable = try await fixture.router.nowPlaying()
        XCTAssertEqual(unavailable, .empty)
        XCTAssertEqual(fixture.registry.sourceStatus, .unavailable("QQ 音乐"))
        await assertNoPlaybackCalls(fixture)

        try fixture.grant(.readMedia, provider: AutomaticMusicFixture.qqID)
        let available = try await fixture.router.nowPlaying()
        XCTAssertEqual(available.title, AutomaticMusicFixture.qqBundle + " song")
        XCTAssertEqual(fixture.registry.sourceStatus, .active("QQ 音乐"))
        let history = await fixture.runner.history()
        XCTAssertEqual(history, [[AutomaticMusicFixture.qqBundle, "nowPlaying"]])
    }

    func testReadOnlyActiveSourceDisplaysMetadataButCannotControlPlayback() async throws {
        let fixture = try AutomaticMusicFixture()
        defer { fixture.shutdown() }
        try fixture.grant(.readMedia, provider: AutomaticMusicFixture.spotifyID)
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.spotifyBundle))
        _ = try await fixture.router.nowPlaying()
        do {
            try await fixture.router.togglePlayPause()
            XCTFail("Detecting an app must not grant playback control.")
        } catch { XCTAssertEqual(error as? PluginPermissionError, .notGranted) }
        let history = await fixture.runner.history()
        XCTAssertEqual(history, [[AutomaticMusicFixture.spotifyBundle, "nowPlaying"]])
        let fallbackActions = await fixture.fallback.actions()
        XCTAssertTrue(fallbackActions.isEmpty)
    }

    func testRegrantingMediaPermissionRequiresFreshMetadataBeforeControlCanResume() async throws {
        for permission in [PluginPermission.readMedia, .controlMedia] {
            let fixture = try AutomaticMusicFixture()
            defer { fixture.shutdown() }
            try fixture.grant(.readMedia, provider: AutomaticMusicFixture.qqID)
            try fixture.grant(.controlMedia, provider: AutomaticMusicFixture.qqID)
            await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.qqBundle))
            _ = try await fixture.router.nowPlaying()

            try fixture.revoke(permission, provider: AutomaticMusicFixture.qqID)
            try fixture.grant(permission, provider: AutomaticMusicFixture.qqID)
            await assertControlRejected { try await fixture.router.togglePlayPause() }
            let beforeFreshMetadata = await fixture.runner.history()
            XCTAssertEqual(beforeFreshMetadata, [[AutomaticMusicFixture.qqBundle, "nowPlaying"]],
                           "Regranting \(permission) must not revive an earlier display's control binding.")

            _ = try await fixture.router.nowPlaying()
            try await fixture.router.togglePlayPause()
            let afterFreshMetadata = await fixture.runner.history()
            XCTAssertEqual(afterFreshMetadata, [
                [AutomaticMusicFixture.qqBundle, "nowPlaying"],
                [AutomaticMusicFixture.qqBundle, "nowPlaying"],
                [AutomaticMusicFixture.qqBundle, "togglePlayPause"]
            ])
        }
    }

    func testDetectionAloneDoesNotBindButtonsBeforeMetadataHasBeenDisplayed() async throws {
        let fixture = try AutomaticMusicFixture()
        defer { fixture.shutdown() }
        try fixture.grantBoth(.readMedia)
        try fixture.grantBoth(.controlMedia)
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.spotifyBundle))
        await assertControlRejected { try await fixture.router.togglePlayPause() }
        await assertNoPlaybackCalls(fixture)
    }

    func testSourceChangeRejectsTheOldButtonInsteadOfControllingTheNewPlayer() async throws {
        let fixture = try AutomaticMusicFixture()
        defer { fixture.shutdown() }
        try fixture.grantBoth(.readMedia)
        try fixture.grantBoth(.controlMedia)
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.qqBundle))
        _ = try await fixture.router.nowPlaying()
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.spotifyBundle))
        await assertControlRejected { try await fixture.router.togglePlayPause() }
        let afterOldButton = await fixture.runner.history()
        XCTAssertEqual(afterOldButton, [[AutomaticMusicFixture.qqBundle, "nowPlaying"]])

        let newInfo = try await fixture.router.nowPlaying()
        XCTAssertEqual(newInfo.title, AutomaticMusicFixture.spotifyBundle + " song")
        try await fixture.router.togglePlayPause()
        let afterNewButton = await fixture.runner.history()
        XCTAssertEqual(afterNewButton, [
            [AutomaticMusicFixture.qqBundle, "nowPlaying"],
            [AutomaticMusicFixture.spotifyBundle, "nowPlaying"],
            [AutomaticMusicFixture.spotifyBundle, "togglePlayPause"]
        ])
        let fallbackActions = await fixture.fallback.actions()
        XCTAssertTrue(fallbackActions.isEmpty)
    }

    func testSourceChangeFromAppleMusicCannotRetargetAnOldTransportButton() async throws {
        let fixture = try AutomaticMusicFixture()
        defer { fixture.shutdown() }
        try fixture.grantBoth(.readMedia)
        try fixture.grantBoth(.controlMedia)
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.appleBundle))
        _ = try await fixture.router.nowPlaying()
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.qqBundle))
        await assertControlRejected { try await fixture.router.skipBackward() }
        let history = await fixture.runner.history()
        let fallbackActions = await fixture.fallback.actions()
        XCTAssertTrue(history.isEmpty)
        XCTAssertTrue(fallbackActions.isEmpty)
    }

    func testOpaqueSeekHandlesAreIsolatedAcrossSourcesEvenWhenRawIDsCollide() async throws {
        let fixture = try AutomaticMusicFixture()
        defer { fixture.shutdown() }
        try fixture.grantBoth(.readMedia)
        try fixture.grantBoth(.controlMedia)
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.qqBundle))
        let qq = try await fixture.router.nowPlaying()
        let qqSeek = try await fixture.router.seek(to: 30, trackIdentifier: qq.trackIdentifier)
        XCTAssertTrue(qqSeek)
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.spotifyBundle))
        let spotify = try await fixture.router.nowPlaying()
        XCTAssertNotEqual(qq.trackIdentifier, spotify.trackIdentifier)
        await assertSeekRejected { try await fixture.router.seek(to: 40, trackIdentifier: qq.trackIdentifier) }
        let spotifySeek = try await fixture.router.seek(to: 50, trackIdentifier: spotify.trackIdentifier)
        XCTAssertTrue(spotifySeek)
        let history = await fixture.runner.history()
        XCTAssertEqual(history, [
            [AutomaticMusicFixture.qqBundle, "nowPlaying"],
            [AutomaticMusicFixture.qqBundle, "seek", "30.0", "shared-track"],
            [AutomaticMusicFixture.spotifyBundle, "nowPlaying"],
            [AutomaticMusicFixture.spotifyBundle, "seek", "50.0", "shared-track"]
        ])
    }

    func testAppleMusicSeekUnwrapsOnlyItsOwnDisplayedHandle() async throws {
        let fixture = try AutomaticMusicFixture()
        defer { fixture.shutdown() }
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.appleBundle))
        let info = try await fixture.router.nowPlaying()
        XCTAssertNotEqual(info.trackIdentifier, "shared-track")
        let sought = try await fixture.router.seek(to: 25, trackIdentifier: info.trackIdentifier)
        XCTAssertTrue(sought)
        let seekArguments = await fixture.fallback.seekArguments()
        XCTAssertEqual(seekArguments.map(\.track), ["shared-track"])
        XCTAssertEqual(seekArguments.map(\.position), [25])
    }

    func testAStaleTrackHandleCannotSeekAnotherTrackInTheSameApp() async throws {
        let fixture = try AutomaticMusicFixture()
        defer { fixture.shutdown() }
        try fixture.grant(.readMedia, provider: AutomaticMusicFixture.qqID)
        try fixture.grant(.controlMedia, provider: AutomaticMusicFixture.qqID)
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.qqBundle))
        let first = try await fixture.router.nowPlaying()
        await fixture.runner.setTrack("second-track", for: AutomaticMusicFixture.qqBundle)
        let second = try await fixture.router.nowPlaying()
        XCTAssertNotEqual(first.trackIdentifier, second.trackIdentifier)
        await assertSeekRejected { try await fixture.router.seek(to: 10, trackIdentifier: first.trackIdentifier) }
        let sought = try await fixture.router.seek(to: 20, trackIdentifier: second.trackIdentifier)
        XCTAssertTrue(sought)
        let history = await fixture.runner.history()
        XCTAssertEqual(history.last, [AutomaticMusicFixture.qqBundle, "seek", "20.0", "second-track"])
        XCTAssertEqual(history.filter { $0[1] == "seek" }.count, 1)
    }

    func testDisablingTheActivePluginShowsUnavailableAndDoesNotReadAnotherApp() async throws {
        let fixture = try AutomaticMusicFixture()
        defer { fixture.shutdown() }
        try fixture.grantBoth(.readMedia)
        try fixture.grantBoth(.controlMedia)
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.qqBundle))
        _ = try await fixture.router.nowPlaying()
        fixture.bridge.pluginDidChangeEnablement(id: AutomaticMusicFixture.qqID, isEnabled: false)
        let info = try await fixture.router.nowPlaying()
        XCTAssertEqual(info, .empty)
        XCTAssertEqual(fixture.registry.sourceStatus, .unavailable("QQ 音乐"))
        await assertControlRejected { try await fixture.router.skipForward() }
        let history = await fixture.runner.history()
        XCTAssertEqual(history, [[AutomaticMusicFixture.qqBundle, "nowPlaying"]])
        let fallbackReads = await fixture.fallback.reads()
        XCTAssertEqual(fallbackReads, 0)
    }

    func testAnIdleSampleInvalidatesThePreviouslyDisplayedTransportBinding() async throws {
        let fixture = try AutomaticMusicFixture()
        defer { fixture.shutdown() }
        try fixture.grantBoth(.readMedia)
        try fixture.grantBoth(.controlMedia)
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.qqBundle))
        let oldInfo = try await fixture.router.nowPlaying()
        await fixture.detector.set(.none)
        let idleInfo = try await fixture.router.nowPlaying()
        XCTAssertEqual(idleInfo, .empty)
        XCTAssertEqual(fixture.registry.sourceStatus, .idle)
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.qqBundle))
        await assertControlRejected { try await fixture.router.togglePlayPause() }
        await assertSeekRejected { try await fixture.router.seek(to: 10, trackIdentifier: oldInfo.trackIdentifier) }
        let history = await fixture.runner.history()
        XCTAssertEqual(history, [[AutomaticMusicFixture.qqBundle, "nowPlaying"]])
    }

    func testDetectorFailureDoesNotReturnCachedMetadataOrRetainAControlBinding() async throws {
        let fixture = try AutomaticMusicFixture()
        defer { fixture.shutdown() }
        try fixture.grantBoth(.readMedia)
        try fixture.grantBoth(.controlMedia)
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.qqBundle))
        _ = try await fixture.router.nowPlaying()
        await fixture.detector.setFailure(true)
        do {
            let info = try await fixture.router.nowPlaying()
            XCTAssertEqual(info, .empty)
        } catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertEqual(fixture.registry.sourceStatus, .failed)
        await fixture.detector.setFailure(false)
        await assertControlRejected { try await fixture.router.togglePlayPause() }
        let history = await fixture.runner.history()
        XCTAssertEqual(history, [[AutomaticMusicFixture.qqBundle, "nowPlaying"]])
        let fallbackReads = await fixture.fallback.reads()
        XCTAssertEqual(fallbackReads, 0)
    }

    func testConcurrentMetadataRequestsShareOneDetectionAndOneHelperRead() async throws {
        let fixture = try AutomaticMusicFixture()
        defer { fixture.shutdown() }
        try fixture.grant(.readMedia, provider: AutomaticMusicFixture.qqID)
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.qqBundle))
        await fixture.detector.setSuspended(true)
        let first = Task { try await fixture.router.nowPlaying() }
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return try await fixture.router.nowPlaying()
        }
        try await waitUntil {
            let detections = await fixture.detector.calls()
            return secondStarted && detections > 0
        }
        await fixture.detector.setSuspended(false)
        let firstInfo = try await first.value
        let secondInfo = try await second.value
        XCTAssertEqual(firstInfo, secondInfo)
        let detections = await fixture.detector.calls()
        let history = await fixture.runner.history()
        XCTAssertEqual(detections, 1)
        XCTAssertEqual(history, [[AutomaticMusicFixture.qqBundle, "nowPlaying"]])
    }

    func testCancellingAnAutomaticReadCancelsItsPendingDetection() async throws {
        let fixture = try AutomaticMusicFixture()
        defer { fixture.shutdown() }
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.appleBundle))
        await fixture.detector.setSuspended(true)
        let pending = Task { try await fixture.router.nowPlaying() }
        try await waitUntil { await fixture.detector.calls() == 1 }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled source detection returned metadata.") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cancelled = await fixture.detector.cancellations()
        XCTAssertEqual(cancelled, 1)
        await assertNoPlaybackCalls(fixture)
    }

    func testSourceSwitchRejectsARefreshAlreadyWaitingOnTheOldPlayer() async throws {
        let fixture = try AutomaticMusicFixture()
        defer { fixture.shutdown() }
        try fixture.grantBoth(.readMedia)
        try fixture.grantBoth(.controlMedia)
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.qqBundle))
        _ = try await fixture.router.nowPlaying()
        await fixture.runner.setSuspended(true)
        let oldRefresh = Task { try await fixture.router.nowPlaying() }
        try await waitUntil { await fixture.runner.suspendedReads() > 0 }
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.spotifyBundle))
        await assertControlRejected { try await fixture.router.togglePlayPause() }
        do { _ = try await oldRefresh.value; XCTFail("Old player returned after an observed source switch.") }
        catch { XCTAssertTrue(error is CancellationError || error as? PluginMusicError == .sourceChanged) }
        await fixture.runner.setSuspended(false)
        let current = try await fixture.router.nowPlaying()
        XCTAssertEqual(current.title, AutomaticMusicFixture.spotifyBundle + " song")
        let history = await fixture.runner.history()
        XCTAssertEqual(history.last, [AutomaticMusicFixture.spotifyBundle, "nowPlaying"])
        XCTAssertFalse(history.contains { $0[1] != "nowPlaying" })
    }

    func testViewModelFollowsAutomaticSourceChangesWhileContinuouslyCompact() async throws {
        let fixture = try AutomaticMusicFixture()
        defer { fixture.shutdown() }
        try fixture.grantBoth(.readMedia)
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.qqBundle))

        // Use the production convenience path so this model owns its router
        // and its actual registry-generation observer. Known optional sources
        // ensure that the real Apple Music service is never asked to run.
        let model = IslandViewModel(musicProviders: fixture.registry)
        model.setIslandPanelVisible(true)
        defer { model.setIslandPanelVisible(false) }
        try await waitUntil(timeout: .milliseconds(2_800)) {
            model.nowPlaying.title == AutomaticMusicFixture.qqBundle + " song"
        }
        let firstIdentifier = model.nowPlaying.trackIdentifier
        XCTAssertFalse(firstIdentifier.isEmpty)
        XCTAssertEqual(model.presentationState, .compact)
        XCTAssertFalse(model.isHovering)
        XCTAssertFalse(model.isPointerInside)

        var appliedSnapshots: [NowPlayingInfo] = []
        let observation = model.$nowPlaying.sink { appliedSnapshots.append($0) }
        defer { observation.cancel() }
        let changedAt = ContinuousClock.now
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.spotifyBundle))
        // Do not hover, expand, or manually refresh. The existing 1.5-second
        // compact poll must observe the new source and settle its generation.
        try await waitUntil(timeout: .milliseconds(2_800)) {
            model.nowPlaying.title == AutomaticMusicFixture.spotifyBundle + " song"
        }
        XCTAssertLessThan(changedAt.duration(to: ContinuousClock.now), .seconds(3))
        XCTAssertNotEqual(model.nowPlaying.trackIdentifier, firstIdentifier)
        XCTAssertTrue(appliedSnapshots.contains { $0.title.isEmpty && $0.trackIdentifier.isEmpty },
                      "The generation observer must clear the old source before applying the new one.")
        XCTAssertEqual(fixture.registry.sourceStatus, .active("Spotify"))
        XCTAssertEqual(model.presentationState, .compact)
        XCTAssertFalse(model.isHovering)
        XCTAssertFalse(model.isPointerInside)
        let history = await fixture.runner.history()
        XCTAssertTrue(history.contains([AutomaticMusicFixture.qqBundle, "nowPlaying"]))
        XCTAssertTrue(history.contains([AutomaticMusicFixture.spotifyBundle, "nowPlaying"]))
        XCTAssertTrue(history.allSatisfy { $0[1] == "nowPlaying" }, "Automatic detection must not send playback commands.")
    }

    func testAnOldSuccessfulDetectionCannotReplaceANewerActiveSource() async throws {
        try await assertOutOfOrderControlDetectionCannotChangeNewSource(oldDetectionFails: false)
    }

    func testAnOldFailedDetectionCannotClearANewerActiveSource() async throws {
        try await assertOutOfOrderControlDetectionCannotChangeNewSource(oldDetectionFails: true)
    }

    private func assertOutOfOrderControlDetectionCannotChangeNewSource(oldDetectionFails: Bool) async throws {
        let fixture = try AutomaticMusicFixture()
        defer { fixture.shutdown() }
        try fixture.grantBoth(.readMedia)
        try fixture.grantBoth(.controlMedia)
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.qqBundle))
        _ = try await fixture.router.nowPlaying()

        await fixture.detector.setFailure(oldDetectionFails)
        await fixture.detector.suspendNextSnapshot()
        let oldControl = Task { try await fixture.router.togglePlayPause() }
        defer { oldControl.cancel() }
        try await waitUntil { await fixture.detector.hasSuspendedSnapshot() }

        // This newer sample completes while the older control still owns a
        // captured QQ result (or error). Only the next sample was suspended.
        await fixture.detector.set(.source(bundleIdentifier: AutomaticMusicFixture.spotifyBundle))
        await fixture.detector.setFailure(false)
        let current = try await fixture.router.nowPlaying()
        XCTAssertEqual(current.title, AutomaticMusicFixture.spotifyBundle + " song")
        XCTAssertEqual(fixture.registry.selectedProviderID, AutomaticMusicFixture.spotifyID)
        XCTAssertEqual(fixture.registry.sourceStatus, .active("Spotify"))

        await fixture.detector.releaseSnapshot()
        await assertControlRejected { try await oldControl.value }
        XCTAssertEqual(fixture.registry.selectedProviderID, AutomaticMusicFixture.spotifyID,
                       "An older detection must not undo a newer completed source selection.")
        XCTAssertEqual(fixture.registry.sourceStatus, .active("Spotify"),
                       "An older detection error must not erase a newer successful source.")
        let beforeCurrentControl = await fixture.runner.history()
        XCTAssertEqual(beforeCurrentControl, [
            [AutomaticMusicFixture.qqBundle, "nowPlaying"],
            [AutomaticMusicFixture.spotifyBundle, "nowPlaying"]
        ])

        // The stale completion must also leave the new displayed binding
        // usable, instead of merely preserving the status text.
        try await fixture.router.togglePlayPause()
        let afterCurrentControl = await fixture.runner.history()
        XCTAssertEqual(afterCurrentControl, beforeCurrentControl + [
            [AutomaticMusicFixture.spotifyBundle, "togglePlayPause"]
        ])
    }

    private func assertNoPlaybackCalls(_ fixture: AutomaticMusicFixture,
                                       file: StaticString = #filePath, line: UInt = #line) async {
        let history = await fixture.runner.history()
        let reads = await fixture.fallback.reads()
        let actions = await fixture.fallback.actions()
        XCTAssertTrue(history.isEmpty, file: file, line: line)
        XCTAssertEqual(reads, 0, file: file, line: line)
        XCTAssertTrue(actions.isEmpty, file: file, line: line)
    }

    private func assertControlRejected(_ operation: () async throws -> Void,
                                       file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("An unbound or changed source accepted playback control.", file: file, line: line) }
        catch { /* The observable gate is that no player received the command. */ }
    }

    private func assertSeekRejected(_ operation: () async throws -> Bool,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do { let result = try await operation(); XCTAssertFalse(result, file: file, line: line) }
        catch { /* A changed source may reject with an explicit source error. */ }
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw PluginMusicError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class AutomaticMusicFixture {
    static let appleBundle = "com.apple.Music"
    static let qqBundle = "com.tencent.QQMusicMac"
    static let spotifyBundle = "com.spotify.client"
    static let qqID = "com.dynamicisland.qq-music"
    static let spotifyID = "com.dynamicisland.spotify"

    let detector = AutomaticSourceDetector()
    let runner = AutomaticMusicRunner()
    let fallback = AutomaticAppleMusic()
    let permissions = PermissionManager()
    let registry: OptionalMusicProviderRegistry
    let router: MusicSourceRouter
    let bridge: PluginLifecycleBridge
    private let reviews: [String: PluginPermissionReview]

    init() throws {
        let helper = Data("automatic-source-fixture-helper".utf8)
        let digest = OptionalMusicProviderRegistry.sha256(helper)
        var packages: [ValidatedPluginPackage] = []
        var reviews: [String: PluginPermissionReview] = [:]
        var runtimes: [String: AutomaticProviderRuntime] = [:]
        for (id, name, bundle) in [(Self.qqID, "QQ 音乐", Self.qqBundle), (Self.spotifyID, "Spotify", Self.spotifyBundle)] {
            let descriptor = PluginMediaProviderDescriptor(targetBundleIdentifier: bundle,
                displayName: name, helperPath: "media-helper.js", helperSHA256: digest)
            let manifest = try PluginManifest(id: id, name: name, version: SemanticVersion("1.0.0"),
                engine: .javaScriptCore, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.1"),
                permissions: [.readMedia, .controlMedia], capabilities: [.musicProvider], mediaProvider: descriptor)
            let package = ValidatedPluginPackage(manifest: manifest,
                canonicalRootURL: URL(fileURLWithPath: "/tmp/automatic-music-fixture/\(id)"),
                entryRelativePath: "index.js", entrySource: Data("function onStart() {}".utf8),
                regularFileCount: 3, totalFileBytes: 100, mediaHelperSource: helper)
            packages.append(package)
            reviews[id] = permissions.request(package: package)
            runtimes[id] = AutomaticProviderRuntime()
        }
        self.reviews = reviews
        registry = OptionalMusicProviderRegistry(runner: runner,
            trustedHelpers: [digest: [Self.qqBundle, Self.spotifyBundle]], sourceDetector: detector)
        router = MusicSourceRouter(registry: registry, fallback: fallback)
        let activities = ActivityManager(configuration: .immediate)
        let fixedRuntimes = runtimes
        bridge = PluginLifecycleBridge(activityManager: activities, actionRouter: ActionRouter(manager: activities),
            permissions: permissions, musicProviders: registry,
            runtimeFactory: { fixedRuntimes[$0.manifest.id]! })
        for package in packages { bridge.pluginDidLoad(package, isEnabled: true) }
    }

    func grant(_ permission: PluginPermission, provider: String) throws {
        try permissions.applyHostDecision(decision: .granted,
            review: try XCTUnwrap(reviews[provider]), permission: permission)
    }

    func grantBoth(_ permission: PluginPermission) throws {
        for provider in [Self.qqID, Self.spotifyID] { try grant(permission, provider: provider) }
    }

    func revoke(_ permission: PluginPermission, provider: String) throws {
        try permissions.applyHostDecision(decision: .revoked,
            review: try XCTUnwrap(reviews[provider]), permission: permission)
    }

    func shutdown() {
        bridge.shutdown()
        registry.shutdown()
        Task {
            await detector.setSuspended(false)
            await detector.releaseSnapshot()
            await runner.setSuspended(false)
        }
    }
}

@MainActor
private final class AutomaticProviderRuntime: PluginLifecycleRuntime {
    func onStart(context: PluginExecutionContext) throws {}
    func onStop(reason: PluginStopReason) throws {}
    func teardown() {}
}

private actor AutomaticSourceDetector: MusicSourceDetecting {
    private var source: MusicSourceDetection = .none
    private var failed = false
    private var suspended = false
    private var callCount = 0
    private var cancellationCount = 0
    private var suspendNext = false
    private var suspendedSnapshot: (source: MusicSourceDetection, failed: Bool,
                                    continuation: CheckedContinuation<MusicSourceDetection, Error>)?

    nonisolated func activeSource() async throws -> MusicSourceDetection { try await sample() }

    private func sample() async throws -> MusicSourceDetection {
        callCount += 1
        if suspendNext {
            suspendNext = false
            let capturedSource = source
            let capturedFailure = failed
            // Deliberately retain the sampled response even if other calls
            // change actor state before this continuation is released.
            return try await withCheckedThrowingContinuation { continuation in
                suspendedSnapshot = (capturedSource, capturedFailure, continuation)
            }
        }
        do {
            while suspended { try await Task.sleep(for: .milliseconds(5)) }
            try Task.checkCancellation()
        } catch { cancellationCount += 1; throw error }
        if failed { throw PluginMusicError.helperFailed }
        return source
    }

    func set(_ source: MusicSourceDetection) { self.source = source }
    func setFailure(_ failed: Bool) { self.failed = failed }
    func setSuspended(_ suspended: Bool) { self.suspended = suspended }
    func suspendNextSnapshot() { suspendNext = true }
    func hasSuspendedSnapshot() -> Bool { suspendedSnapshot != nil }
    func releaseSnapshot() {
        guard let snapshot = suspendedSnapshot else { return }
        suspendedSnapshot = nil
        if snapshot.failed { snapshot.continuation.resume(throwing: PluginMusicError.helperFailed) }
        else { snapshot.continuation.resume(returning: snapshot.source) }
    }
    func calls() -> Int { callCount }
    func cancellations() -> Int { cancellationCount }
}

private actor AutomaticMusicRunner: PluginMusicHelperRunning {
    private var calls: [[String]] = []
    private var tracks: [String: String] = [:]
    private var suspended = false
    private var suspendedCount = 0

    func run(source: String, arguments: [String], admission: PluginMusicHelperAdmission) async throws -> Data {
        try Task.checkCancellation()
        try admission.perform {}
        calls.append(arguments)
        if arguments[1] != "nowPlaying" { return Data(#"{"ok":true}"#.utf8) }
        if suspended {
            suspendedCount += 1
            defer { suspendedCount -= 1 }
            while suspended { try await Task.sleep(for: .milliseconds(5)) }
        }
        try Task.checkCancellation()
        try admission.perform {}
        return try JSONSerialization.data(withJSONObject: [
            "isPlaying": true, "title": arguments[0] + " song", "artist": "Fixture artist", "album": "Fixture album",
            "duration": 100, "position": 20, "trackIdentifier": tracks[arguments[0]] ?? "shared-track"
        ])
    }

    func setTrack(_ track: String, for bundle: String) { tracks[bundle] = track }
    func setSuspended(_ suspended: Bool) { self.suspended = suspended }
    func suspendedReads() -> Int { suspendedCount }
    func history() -> [[String]] { calls }
}

private actor AutomaticAppleMusic: MusicControlService {
    struct Seek: Sendable { let position: TimeInterval; let track: String }
    private var readCount = 0
    private var calls: [String] = []
    private var seeks: [Seek] = []

    func nowPlaying() -> NowPlayingInfo {
        readCount += 1
        return NowPlayingInfo(isPlaying: true, title: "Apple Music song", artist: "Fixture artist", album: "Fixture album",
                              duration: 100, position: 20, trackIdentifier: "shared-track")
    }
    func togglePlayPause() { calls.append("togglePlayPause") }
    func skipBackward() { calls.append("skipBackward") }
    func skipForward() { calls.append("skipForward") }
    func seek(to position: TimeInterval, trackIdentifier: String) -> Bool {
        calls.append("seek")
        seeks.append(.init(position: position, track: trackIdentifier))
        return true
    }
    func reads() -> Int { readCount }
    func actions() -> [String] { calls }
    func seekArguments() -> [Seek] { seeks }
}
