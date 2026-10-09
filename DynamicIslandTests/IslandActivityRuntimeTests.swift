import AppKit
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandActivityRuntimeTests: XCTestCase {
    func testProductionRuntimeExecutesJavaScriptAndKeepsOtherPluginAdmissionOpen() async throws {
        let runtime = IslandActivityRuntime(viewModel: .preview())
        defer { runtime.pluginLifecycle.shutdown() }
        func package(id: String, source: String) throws -> ValidatedPluginPackage {
            let manifest = try PluginManifest(
                id: id, name: "Production Runtime Test", version: SemanticVersion("1.0.0"),
                engine: .javaScriptCore, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"),
                permissions: [], capabilities: []
            )
            return .init(
                manifest: manifest,
                canonicalRootURL: URL(fileURLWithPath: "/runtime-tests/\(id)", isDirectory: true),
                entryRelativePath: "index.js", entrySource: Data(source.utf8),
                regularFileCount: 2, totalFileBytes: UInt64(source.utf8.count)
            )
        }
        let failedID = "com.example.production-failed"
        let runningID = "com.example.production-running"
        runtime.pluginLifecycle.pluginDidLoad(try package(id: runningID, source: ""), isEnabled: true)
        runtime.pluginLifecycle.pluginDidLoad(
            try package(id: failedID, source: "throw new Error('production execution');"), isEnabled: true
        )
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while runtime.pluginLifecycle.snapshot(id: failedID)?.lastFailure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(runtime.pluginLifecycle.snapshot(id: failedID)?.lastFailure, .startFailed)
        XCTAssertEqual(runtime.pluginLifecycle.snapshot(id: failedID)?.state, .stopped)
        XCTAssertTrue(runtime.pluginLifecycle.allowsExecution(id: runningID))
        XCTAssertEqual(runtime.manager.current?.source, MusicActivityProvider.source)
    }

    func testProductionRuntimeSharesMusicActivityAndActionRouter() throws {
        let viewModel = IslandViewModel.preview()
        let runtime = IslandActivityRuntime(viewModel: viewModel)
        let snapshot = try XCTUnwrap(runtime.manager.currentSnapshot)

        XCTAssertEqual(snapshot.activity.id, MusicActivityProvider.activityID)
        XCTAssertEqual(snapshot.activity.source, MusicActivityProvider.source)
        XCTAssertEqual(snapshot.activity.lifecycle.policy, .persistent)
        XCTAssertFalse(runtime.isCompactActivityVisible)

        let result = runtime.router.dispatch(
            id: snapshot.activity.id,
            source: snapshot.activity.source,
            instanceToken: snapshot.instanceToken,
            action: .init(actionID: MusicActivityProvider.volumeActionID, value: .sliderCommit(0.75))
        )

        XCTAssertEqual(result, .handled)
        XCTAssertEqual(viewModel.volume, 0.75, accuracy: 0.001)
        XCTAssertEqual(runtime.manager.currentSnapshot?.instanceToken, snapshot.instanceToken)
    }

    func testRuntimeUsesCurrentPresentationForCompactVisibility() throws {
        let runtime = IslandActivityRuntime(viewModel: .preview())
        let source = ActivitySource(kind: .builtIn, identifier: "test")
        try runtime.manager.publish(IslandActivity(
            id: "test.hidden",
            source: source,
            priority: .critical,
            lifecycle: .init(policy: .critical),
            presentation: .init(title: "Hidden", showsCompact: false),
            createdAt: Date()
        ))

        XCTAssertEqual(runtime.manager.current?.id, "test.hidden")
        XCTAssertFalse(runtime.isCompactActivityVisible)
        XCTAssertTrue(runtime.prioritizesCurrentActivityOverLegacyContent)
        try runtime.manager.end(id: "test.hidden", source: source)
        XCTAssertFalse(runtime.prioritizesCurrentActivityOverLegacyContent)

        try runtime.manager.publish(IslandActivity(
            id: "test.visible",
            source: source,
            priority: .critical,
            lifecycle: .init(policy: .critical),
            presentation: .init(title: "Visible", showsCompact: true),
            createdAt: Date()
        ))

        XCTAssertEqual(runtime.manager.current?.id, "test.visible")
        XCTAssertTrue(runtime.isCompactActivityVisible)
        XCTAssertTrue(runtime.prioritizesCurrentActivityOverLegacyContent)
    }

    func testRuntimePublishesExternalVolumeChangeWithoutTreatingMusicControlAsSystemHUD() async throws {
        let volume = RuntimeVolumeService(initialVolume: 0.5)
        let model = IslandViewModel(
            volumeService: volume,
            fileTrayService: MusicActivityTestTray(),
            sharingService: MusicActivityTestSharing(),
            musicService: MusicActivityTestService(info: .empty),
            hapticFeedbackService: MusicActivityTestHaptic(),
            nowPlayingPollIntervalNanoseconds: 3_600_000_000_000
        )
        let runtime = IslandActivityRuntime(viewModel: model)

        XCTAssertEqual(runtime.manager.current?.id, MusicActivityProvider.activityID)
        XCTAssertFalse(runtime.prioritizesCurrentActivityOverLegacyContent)

        model.setVolume(0.7)
        volume.simulateExternal(volume: 0.7, isMuted: false)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(runtime.manager.current?.id, MusicActivityProvider.activityID)

        volume.simulateExternal(volume: 0.4, isMuted: false)
        for _ in 0..<200 where runtime.manager.current?.id != VolumeActivityProvider.activityID {
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(runtime.manager.current?.id, VolumeActivityProvider.activityID)
        XCTAssertEqual(runtime.manager.current?.presentation.progress ?? -1, 0.4, accuracy: 0.000_1)
        XCTAssertTrue(runtime.isCompactActivityVisible)
        XCTAssertTrue(runtime.prioritizesCurrentActivityOverLegacyContent)
        XCTAssertTrue(runtime.currentActivityUsesVolumeCompactLayout)
        XCTAssertFalse(runtime.currentActivityUsesBatteryCompactLayout)
    }

    func testRuntimeForwardsOwnedArtworkToMusicProviderAndScopesOtherResources() async throws {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let artworkData = try XCTUnwrap(image.tiffRepresentation)
        let service = MusicActivityTestService(info: NowPlayingInfo(
            isPlaying: true,
            title: "Resolver",
            artist: "Artist",
            album: "Album",
            trackIdentifier: "resolver-track",
            artworkData: artworkData
        ))
        let model = makeMusicActivityTestModel(music: service)
        await model.refreshNowPlaying()
        let runtime = IslandActivityRuntime(viewModel: model)
        let artwork = IslandNode.ImageSource.brokerResource(id: MusicActivityProvider.artworkResourceID)

        XCTAssertNotNil(runtime.resolveImage(artwork, for: MusicActivityProvider.source))
        XCTAssertNil(runtime.resolveImage(
            artwork,
            for: ActivitySource(kind: .builtIn, identifier: "another-provider")
        ))
        XCTAssertNil(runtime.resolveImage(
            .brokerResource(id: "another.resource"),
            for: MusicActivityProvider.source
        ))
    }

    func testMusicPlayingAndPausedUpdatesDriveRuntimeCompactVisibility() async throws {
        let service = MusicActivityTestService(info: NowPlayingInfo(
            isPlaying: true,
            title: "正在播放",
            artist: "艺人",
            album: "专辑",
            trackIdentifier: "visibility-track"
        ))
        let model = makeMusicActivityTestModel(music: service)
        await model.refreshNowPlaying()
        let runtime = IslandActivityRuntime(viewModel: model)

        XCTAssertEqual(runtime.manager.currentSnapshot?.activity.presentation.title, "正在播放")
        XCTAssertTrue(runtime.isCompactActivityVisible)

        await service.setInfo(NowPlayingInfo(
            isPlaying: false,
            title: "已暂停",
            artist: "艺人",
            album: "专辑",
            trackIdentifier: "visibility-track"
        ))
        await model.refreshNowPlaying()

        XCTAssertEqual(runtime.manager.currentSnapshot?.activity.presentation.title, "已暂停")
        XCTAssertFalse(runtime.isCompactActivityVisible)
    }

    func testBatteryCriticalTransitionsToChargingThenRecoveryRestoresSameMusicInstance() async throws {
        let battery = RuntimeBatteryService(state: BatteryState(
            level: 0.65,
            powerSource: .battery,
            isCharging: false,
            isCharged: false
        ))
        let model = IslandViewModel.preview()
        let runtime = IslandActivityRuntime(
            viewModel: model,
            batteryService: battery,
            batteryDebounceNanoseconds: 0
        )
        let music = try XCTUnwrap(runtime.manager.currentSnapshot)
        XCTAssertEqual(music.activity.id, MusicActivityProvider.activityID)

        battery.emit(BatteryState(
            level: 0.08,
            powerSource: .battery,
            isCharging: false,
            isCharged: false
        ))
        try await waitForRuntime { runtime.manager.current?.id == BatteryActivityProvider.activityID }

        XCTAssertEqual(runtime.manager.current?.priority, .critical)
        XCTAssertTrue(runtime.prioritizesCurrentActivityOverLegacyContent)
        XCTAssertTrue(runtime.isCompactActivityVisible)
        XCTAssertTrue(runtime.currentActivityUsesBatteryCompactLayout)
        XCTAssertFalse(runtime.currentActivityUsesVolumeCompactLayout)
        let critical = try XCTUnwrap(runtime.manager.currentSnapshot)

        battery.emit(BatteryState(
            level: 0.08,
            powerSource: .ac,
            isCharging: false,
            isCharged: false
        ))
        try await waitForRuntime {
            runtime.manager.current?.id == BatteryActivityProvider.activityID
                && runtime.manager.current?.priority == .important
        }

        let charging = try XCTUnwrap(runtime.manager.currentSnapshot)
        XCTAssertNotEqual(charging.instanceToken, critical.instanceToken)
        XCTAssertEqual(charging.activity.lifecycle.policy, .transient)
        XCTAssertTrue(runtime.prioritizesCurrentActivityOverLegacyContent)

        battery.emit(BatteryState(
            level: 0.65,
            powerSource: .battery,
            isCharging: false,
            isCharged: false
        ))
        try await waitForRuntime { runtime.manager.current?.id == MusicActivityProvider.activityID }

        XCTAssertEqual(runtime.manager.currentSnapshot?.instanceToken, music.instanceToken)
        XCTAssertNil(runtime.manager.activity(id: BatteryActivityProvider.activityID))
        XCTAssertFalse(runtime.prioritizesCurrentActivityOverLegacyContent)
        XCTAssertFalse(runtime.currentActivityUsesBatteryCompactLayout)
        XCTAssertFalse(runtime.currentActivityUsesVolumeCompactLayout)
    }

    func testTransientActivityPreservesTimerCompletionUntilLegacyToolsRestore() throws {
        let model = IslandViewModel.preview()
        let completedAt = Date(timeIntervalSinceReferenceDate: 120_000)
        model.timerTools.selectedMode = .pomodoro
        model.timerTools.startSelectedTimer(at: completedAt)
        model.timerTools.refresh(
            at: completedAt.addingTimeInterval(model.timerTools.pomodoroDuration)
        )
        XCTAssertTrue(model.isTimerCompletionPresented)
        XCTAssertEqual(model.timerTools.completedMode, .pomodoro)
        XCTAssertEqual(model.expandedSurface, .tools)
        XCTAssertEqual(model.presentationState, .expanded)

        let runtime = IslandActivityRuntime(viewModel: model)
        let music = try XCTUnwrap(runtime.manager.currentSnapshot)
        try publishTransientOverride(in: runtime)

        XCTAssertEqual(runtime.manager.current?.id, BatteryActivityProvider.activityID)
        XCTAssertTrue(runtime.prioritizesCurrentActivityOverLegacyContent)
        XCTAssertTrue(model.isTimerCompletionPresented)
        XCTAssertEqual(model.timerTools.completedMode, .pomodoro)
        XCTAssertEqual(model.expandedSurface, .tools)
        XCTAssertEqual(model.presentationState, .expanded)

        try runtime.manager.end(
            id: BatteryActivityProvider.activityID,
            source: BatteryActivityProvider.source
        )

        XCTAssertEqual(runtime.manager.current?.id, MusicActivityProvider.activityID)
        XCTAssertEqual(runtime.manager.currentSnapshot?.instanceToken, music.instanceToken)
        XCTAssertFalse(runtime.prioritizesCurrentActivityOverLegacyContent)
        XCTAssertTrue(model.isTimerCompletionPresented)
        XCTAssertEqual(model.timerTools.completedMode, .pomodoro)
        XCTAssertEqual(model.expandedSurface, .tools)
        XCTAssertEqual(model.presentationState, .expanded)

        model.acknowledgeTimerCompletion()
        XCTAssertFalse(model.isTimerCompletionPresented)
        XCTAssertNil(model.timerTools.completedMode)
        XCTAssertEqual(model.presentationState, .compact)
    }

    func testTransientActivityPreservesLockedFileTrayUntilLegacyTrayRestores() throws {
        let model = IslandViewModel(
            volumeService: RuntimeVolumeService(initialVolume: 0.5),
            fileTrayService: RuntimeFileTrayService(),
            sharingService: MusicActivityTestSharing(),
            musicService: MusicActivityTestService(info: .empty),
            hapticFeedbackService: MusicActivityTestHaptic(),
            nowPlayingPollIntervalNanoseconds: 3_600_000_000_000
        )
        model.setHovering(true)
        model.importFiles(from: [URL(fileURLWithPath: "/tmp/runtime-tray.txt")])
        model.toggleFileTrayLock()
        model.endHovering()
        let trayItems = model.trayItems
        XCTAssertEqual(trayItems.count, 1)
        XCTAssertTrue(model.isFileTrayLocked)
        XCTAssertEqual(model.expandedSurface, .fileTray)
        XCTAssertEqual(model.presentationState, .expanded)

        let runtime = IslandActivityRuntime(viewModel: model)
        let music = try XCTUnwrap(runtime.manager.currentSnapshot)
        try publishTransientOverride(in: runtime)

        XCTAssertEqual(runtime.manager.current?.id, BatteryActivityProvider.activityID)
        XCTAssertTrue(runtime.prioritizesCurrentActivityOverLegacyContent)
        XCTAssertEqual(model.trayItems, trayItems)
        XCTAssertTrue(model.isFileTrayLocked)
        XCTAssertEqual(model.expandedSurface, .fileTray)
        XCTAssertEqual(model.presentationState, .expanded)

        try runtime.manager.end(
            id: BatteryActivityProvider.activityID,
            source: BatteryActivityProvider.source
        )

        XCTAssertEqual(runtime.manager.current?.id, MusicActivityProvider.activityID)
        XCTAssertEqual(runtime.manager.currentSnapshot?.instanceToken, music.instanceToken)
        XCTAssertFalse(runtime.prioritizesCurrentActivityOverLegacyContent)
        XCTAssertEqual(model.trayItems, trayItems)
        XCTAssertTrue(model.isFileTrayLocked)
        XCTAssertEqual(model.expandedSurface, .fileTray)
        XCTAssertEqual(model.presentationState, .expanded)
    }

    private func publishTransientOverride(in runtime: IslandActivityRuntime) throws {
        try runtime.manager.publish(BatteryActivityProvider.makeActivity(
            for: BatteryState(
                level: 0.18,
                powerSource: .battery,
                isCharging: false,
                isCharged: false
            ),
            classification: .low,
            createdAt: Date()
        ))
    }

    private func waitForRuntime(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for Activity runtime")
    }
}

private struct RuntimeFileTrayService: FileTrayService {
    func importFiles(from urls: [URL]) throws -> [TrayFileItem] {
        urls.map { url in
            TrayFileItem(url: url, originalURL: url, byteCount: 128)
        }
    }

    func remove(_ item: TrayFileItem) throws {}
    func clear() throws {}
}

private final class RuntimeBatteryService: BatteryService, @unchecked Sendable {
    private let lock = NSLock()
    private var state: BatteryState?
    private var handler: (@Sendable () -> Void)?

    init(state: BatteryState?) {
        self.state = state
    }

    func currentState() throws -> BatteryState? {
        lock.withLock { state }
    }

    func observeChanges(_ handler: @escaping @Sendable () -> Void) throws -> BatteryObservation? {
        lock.withLock { self.handler = handler }
        return nil
    }

    func emit(_ state: BatteryState?) {
        let callback = lock.withLock { () -> (@Sendable () -> Void)? in
            self.state = state
            return handler
        }
        callback?()
    }
}

private final class RuntimeVolumeService: VolumeService, @unchecked Sendable {
    private let lock = NSLock()
    private var level: Float
    private var muted = false
    private var observation: (@Sendable () -> Void)?

    init(initialVolume: Float) {
        level = initialVolume
    }

    func currentVolume() throws -> Float {
        lock.withLock { level }
    }

    func isMuted() throws -> Bool {
        lock.withLock { muted }
    }

    func setVolume(_ volume: Float) throws {
        lock.withLock {
            level = volume
            muted = volume == 0
        }
    }

    func setMuted(_ muted: Bool) throws {
        lock.withLock { self.muted = muted }
    }

    func observeVolumeChanges(_ handler: @escaping @Sendable () -> Void) throws -> VolumeObservation? {
        lock.withLock { observation = handler }
        return nil
    }

    func simulateExternal(volume: Float, isMuted: Bool) {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            level = volume
            muted = isMuted
            return observation
        }
        handler?()
    }
}
