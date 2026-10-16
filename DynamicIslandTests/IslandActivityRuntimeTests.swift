import AppKit
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandActivityRuntimeTests: XCTestCase {
    func testCountdownBusinessChangesInvalidateHostDisplayAndShutdownClosesItsClock() async throws {
        let model = IslandViewModel.preview()
        let runtime = IslandActivityRuntime(viewModel: model)
        let clock = runtime.countdownDisplayClock
        defer { runtime.shutdownPlugins() }
        let broker = runtime.pluginLifecycle.countdownBroker
        let owner = try broker.registerOwner(pluginID: "com.example.runtime-display")
        let revision = clock.revision
        _ = try broker.start(owner: owner, id: "focus", durationMilliseconds: 60_000)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertGreaterThan(clock.revision, revision)
        XCTAssertEqual(clock.timerCount, 0, "Business invalidation must not create a display timer")
        let consumer = UUID()
        clock.setNeedsTicks(true, for: consumer)
        XCTAssertEqual(clock.timerCount, 1)
        runtime.shutdownPlugins()
        XCTAssertEqual(clock.consumerCount, 0)
        XCTAssertEqual(clock.timerCount, 0)
        let stoppedRevision = clock.revision
        clock.setNeedsTicks(true, for: UUID())
        clock.invalidate()
        XCTAssertEqual(clock.timerCount, 0)
        XCTAssertEqual(clock.revision, stoppedRevision)
        XCTAssertEqual(broker.diagnostics.recordCount, 0)
    }

    func testAutomaticToolUsesCompactContextAndPreservesExpandedLegacyChoices() async throws {
        let service = MusicActivityTestService(info: NowPlayingInfo(
            isPlaying: true, title: "Playing music", artist: "Artist", album: "Album", trackIdentifier: "automatic-tool-track"
        ))
        let model = makeMusicActivityTestModel(music: service)
        await model.refreshNowPlaying()
        let runtime = IslandActivityRuntime(viewModel: model)
        defer { runtime.shutdownPlugins() }
        let music = try XCTUnwrap(runtime.manager.currentSnapshot)
        XCTAssertTrue(runtime.isCompactActivityVisible)
        let activity = automaticCompactTool()
        var actions: [RoutedActivityAction] = []
        runtime.router.register(source: activity.source) { actions.append($0) }
        try runtime.manager.publish(activity)
        try await waitForTool { runtime.manager.current?.id == activity.id }
        let compact = try XCTUnwrap(runtime.manager.currentSnapshot)
        XCTAssertNil(runtime.manager.selectedToolSnapshot)
        XCTAssertTrue(runtime.currentActivityUsesCountdownCompactLayout)
        XCTAssertEqual(dispatchTool(compact, in: runtime), .handled)
        XCTAssertEqual(actions.last?.instanceToken, compact.instanceToken)

        // @Published emits before isHovering is stored: this must still switch
        // eligibility synchronously using the delivered expansion state.
        model.setHovering(true)
        XCTAssertEqual(runtime.manager.currentSnapshot?.instanceToken, music.instanceToken)
        XCTAssertFalse(runtime.currentActivityUsesCountdownCompactLayout)
        XCTAssertEqual(dispatchTool(compact, in: runtime), .inactiveActivity)
        let inventory = try XCTUnwrap(runtime.manager.toolSnapshots.first)
        XCTAssertTrue(runtime.selectTool(inventory))
        XCTAssertEqual(runtime.manager.currentSnapshot?.instanceToken, compact.instanceToken)
        XCTAssertEqual(dispatchTool(compact, in: runtime), .handled)

        for surface in [IslandExpandedSurface.music, .fileTray, .tools] {
            XCTAssertTrue(runtime.selectTool(inventory))
            runtime.selectLegacySurface(surface)
            XCTAssertEqual(model.expandedSurface, surface)
            XCTAssertNil(runtime.manager.selectedToolSnapshot)
            XCTAssertEqual(runtime.manager.currentSnapshot?.instanceToken, music.instanceToken)
            XCTAssertEqual(dispatchTool(compact, in: runtime), .inactiveActivity)
        }
        model.endHovering()
        try await waitForTool { runtime.manager.currentSnapshot?.instanceToken == compact.instanceToken }
        XCTAssertNil(runtime.manager.selectedToolSnapshot)
        XCTAssertTrue(runtime.currentActivityUsesCountdownCompactLayout)
        XCTAssertEqual(dispatchTool(compact, in: runtime), .handled)

        // Ending and reusing an ID must never authorize the old captured view.
        try runtime.manager.end(id: activity.id, source: activity.source)
        try runtime.manager.publish(automaticCompactTool())
        try await waitForTool { runtime.manager.current?.id == activity.id }
        let replacement = try XCTUnwrap(runtime.manager.currentSnapshot)
        XCTAssertNotEqual(replacement.instanceToken, compact.instanceToken)
        XCTAssertEqual(dispatchTool(compact, in: runtime), .inactiveActivity)
        XCTAssertEqual(dispatchTool(replacement, in: runtime), .handled)
    }

    func testAutomaticCompactToolRestoresSameInstanceAfterTransientPreemption() async throws {
        let model = IslandViewModel.preview()
        let runtime = IslandActivityRuntime(viewModel: model)
        defer { runtime.shutdownPlugins() }
        let activity = automaticCompactTool()
        runtime.router.register(source: activity.source) { _ in }
        try runtime.manager.publish(activity)
        try await waitForTool { runtime.manager.current?.id == activity.id }
        let tool = try XCTUnwrap(runtime.manager.currentSnapshot)

        try publishTransientOverride(in: runtime)
        let prompt = try XCTUnwrap(runtime.manager.currentSnapshot)
        XCTAssertEqual(prompt.activity.source, BatteryActivityProvider.source)
        XCTAssertFalse(runtime.currentActivityUsesCountdownCompactLayout)
        XCTAssertNil(runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(dispatchTool(tool, in: runtime), .inactiveActivity)
        try runtime.manager.end(id: prompt.activity.id, source: prompt.activity.source)
        try await waitForTool { runtime.manager.currentSnapshot?.instanceToken == tool.instanceToken }
        XCTAssertTrue(runtime.currentActivityUsesCountdownCompactLayout)
        XCTAssertEqual(dispatchTool(tool, in: runtime), .handled)
    }

    func testAutomaticToolContextTracksInitialExpansionDragTrayLockAndNativeCompletion() async throws {
        let model = IslandViewModel.preview()
        model.setHovering(true)
        let runtime = IslandActivityRuntime(viewModel: model)
        defer { runtime.shutdownPlugins() }
        let music = try XCTUnwrap(runtime.manager.currentSnapshot)
        let activity = automaticCompactTool()
        try runtime.manager.publish(activity)
        XCTAssertEqual(runtime.manager.currentSnapshot?.instanceToken, music.instanceToken,
                       "The initial sink must preserve an already expanded Host.")
        let inventory = try XCTUnwrap(runtime.manager.toolSnapshots.first)
        XCTAssertTrue(runtime.selectTool(inventory))
        model.setDragging(true)
        XCTAssertNil(runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(runtime.manager.currentSnapshot?.instanceToken, music.instanceToken)
        XCTAssertEqual(model.expandedSurface, .fileTray)
        model.endHovering()
        XCTAssertEqual(runtime.manager.currentSnapshot?.instanceToken, music.instanceToken,
                       "Dragging remains expanded even after hover ends.")
        model.setDragging(false)
        try await waitForTool { runtime.manager.current?.id == activity.id }

        model.toggleFileTrayLock()
        XCTAssertEqual(runtime.manager.currentSnapshot?.instanceToken, music.instanceToken)
        XCTAssertNil(runtime.manager.selectedToolSnapshot)
        model.toggleFileTrayLock()
        try await waitForTool { runtime.manager.current?.id == activity.id }

        let startedAt = Date()
        model.timerTools.selectedMode = .countdown
        model.timerTools.startSelectedTimer(at: startedAt)
        model.timerTools.refresh(at: startedAt.addingTimeInterval(model.timerTools.countdownDuration + 1))
        XCTAssertTrue(model.isTimerCompletionPresented)
        XCTAssertEqual(runtime.manager.currentSnapshot?.instanceToken, music.instanceToken)
        XCTAssertNil(runtime.manager.selectedToolSnapshot)
        XCTAssertFalse(runtime.selectTool(inventory))
        model.acknowledgeTimerCompletion()
        try await waitForTool { runtime.manager.current?.id == activity.id }
        XCTAssertTrue(runtime.currentActivityUsesCountdownCompactLayout)
    }

    func testCountdownCompactGeometryUsesOnlyCurrentResolvedCompactTree() throws {
        let model = IslandViewModel.preview()
        let runtime = IslandActivityRuntime(viewModel: model)
        defer { runtime.shutdownPlugins() }
        var activity = automaticCompactTool()
        activity.priority = .critical
        activity.lifecycle = .init(policy: .critical)
        activity.presentation.role = .status
        activity.presentation.compactPolicy = nil
        try runtime.manager.publish(activity)
        XCTAssertTrue(runtime.currentActivityUsesCountdownCompactLayout)
        let base = CGSize(width: 216, height: 38)
        let shell = runtime.compactShellSize(forBaseSize: base)
        XCTAssertEqual(shell.width, base.width + 126)
        XCTAssertEqual(shell.height, base.height)

        // A valid countdown in an expanded layout does not widen compact UI.
        activity.presentation.compact = .text(.init("Ordinary compact"))
        try runtime.manager.update(activity)
        XCTAssertFalse(runtime.currentActivityUsesCountdownCompactLayout)
        XCTAssertEqual(runtime.compactShellSize(forBaseSize: base).width,
                       base.width + IslandVisualStyle.activityCompactHorizontalExpansion)
        // Nor does an oversized compact tree rejected by HostPolicy.
        let countdown = countdownTimeNode()
        activity.presentation.compact = .vStack(.init([countdown, countdown]))
        try runtime.manager.update(activity)
        XCTAssertFalse(runtime.currentActivityUsesCountdownCompactLayout)
        activity.presentation.compact = nil
        activity.presentation.minimal = countdown
        try runtime.manager.update(activity)
        XCTAssertTrue(runtime.currentActivityUsesCountdownCompactLayout,
                      "A compact layout legitimately falling back to minimal uses the same resolver.")
        activity.presentation.showsCompact = false
        try runtime.manager.update(activity)
        XCTAssertFalse(runtime.currentActivityUsesCountdownCompactLayout)
        XCTAssertEqual(runtime.compactShellSize(forBaseSize: base).width, base.width,
                       "A hidden compact layout cannot widen an otherwise empty island.")
        try runtime.manager.end(id: activity.id, source: activity.source)
        model.timerTools.selectedMode = .countdown
        model.timerTools.startSelectedTimer(at: Date())
        XCTAssertEqual(runtime.compactShellSize(forBaseSize: base).width, base.width + 126,
                       "The same production resolver preserves native timer clearance.")
    }

    func testPublicToolExampleRequiresHostSelectionAndRoutesOnlyVisibleInstance() async throws {
        let model = IslandViewModel.preview()
        let runtime = IslandActivityRuntime(viewModel: model)
        defer { runtime.shutdownPlugins() }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/plugin-system/examples/tool-demo", isDirectory: true)
        let package = try PluginValidator().validateExpandedPackage(
            at: root, context: .init(hostVersion: SemanticVersion("0.6.0"), occupiedPluginIDs: [],
                                    allowedContainerURL: root.deletingLastPathComponent())
        )
        runtime.pluginLifecycle.pluginDidLoad(package, isEnabled: true)
        try await waitForTool { runtime.manager.toolSnapshots.count == 1 }
        let tool = try XCTUnwrap(runtime.manager.toolSnapshots.first)
        let source = tool.activity.source
        XCTAssertNotEqual(runtime.manager.current?.id, tool.activity.id)
        XCTAssertFalse(runtime.selectTool(tool), "A folded island cannot choose a tool.")
        XCTAssertEqual(runtime.router.dispatch(id: tool.activity.id, source: source, instanceToken: tool.instanceToken,
                                               action: .init(actionID: "increment", value: .none)), .inactiveActivity)

        model.setHovering(true)
        XCTAssertTrue(runtime.selectTool(tool))
        XCTAssertEqual(model.expandedSurface, .tools)
        XCTAssertEqual(runtime.manager.currentSnapshot?.instanceToken, tool.instanceToken)
        XCTAssertEqual(runtime.expandedShellSize, CGSize(width: 480, height: 200))
        XCTAssertEqual(runtime.router.dispatch(id: tool.activity.id, source: source, instanceToken: tool.instanceToken,
                                               action: .init(actionID: "increment", value: .none)), .handled)
        try await waitForTool {
            runtime.manager.current?.presentation.expanded == .vStack(.init([
                .text(.init("已点击 1 次")),
                .button(.init(actionID: "increment", label: .text(.init("增加一次")), accessibilityLabel: "增加一次"))
            ]))
        }

        try publishTransientOverride(in: runtime)
        XCTAssertFalse(runtime.currentActivityUsesToolLayout)
        XCTAssertEqual(runtime.manager.selectedToolSnapshot?.instanceToken, tool.instanceToken)
        XCTAssertEqual(runtime.router.dispatch(id: tool.activity.id, source: source, instanceToken: tool.instanceToken,
                                               action: .init(actionID: "increment", value: .none)), .inactiveActivity)
        let prompt = try XCTUnwrap(runtime.manager.current)
        try runtime.manager.end(id: prompt.id, source: prompt.source)
        try await waitForTool { runtime.manager.currentSnapshot?.instanceToken == tool.instanceToken }

        runtime.pluginLifecycle.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: false)
        XCTAssertTrue(runtime.manager.toolSnapshots.isEmpty)
        XCTAssertNil(runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(runtime.router.dispatch(id: tool.activity.id, source: source, instanceToken: tool.instanceToken,
                                               action: .init(actionID: "increment", value: .none)), .inactiveActivity)
    }

    func testToolSelectionClearsSynchronouslyOnFoldDragAndLegacySurfaceChoice() throws {
        let model = IslandViewModel.preview()
        let runtime = IslandActivityRuntime(viewModel: model)
        defer { runtime.shutdownPlugins() }
        try runtime.manager.publish(hostTool())
        let tool = try XCTUnwrap(runtime.manager.toolSnapshots.first)

        model.setHovering(true)
        XCTAssertTrue(runtime.selectTool(tool))
        model.endHovering()
        XCTAssertNil(runtime.manager.selectedToolSnapshot)
        XCTAssertFalse(runtime.currentActivityUsesToolLayout)

        model.setHovering(true)
        XCTAssertTrue(runtime.selectTool(tool))
        model.selectExpandedSurface(.music)
        XCTAssertNil(runtime.manager.selectedToolSnapshot)

        XCTAssertTrue(runtime.selectTool(tool))
        runtime.selectLegacySurface(.tools)
        XCTAssertEqual(model.expandedSurface, .tools)
        XCTAssertNil(runtime.manager.selectedToolSnapshot)

        XCTAssertTrue(runtime.selectTool(tool))
        model.setDragging(true)
        XCTAssertNil(runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(model.expandedSurface, .fileTray)
        XCTAssertFalse(runtime.selectTool(tool))
        model.setDragging(false)

        try runtime.manager.end(id: tool.activity.id, source: tool.activity.source)
        model.selectExpandedSurface(.music)
        XCTAssertFalse(runtime.selectTool(tool))
        XCTAssertEqual(model.expandedSurface, .music, "A stale menu must not change the selected surface.")
    }

    func testNativeTimerCompletionClearsToolChoiceAndKeepsItsLegacyGeometry() throws {
        let model = IslandViewModel.preview()
        let runtime = IslandActivityRuntime(viewModel: model)
        defer { runtime.shutdownPlugins() }
        try runtime.manager.publish(hostTool())
        let tool = try XCTUnwrap(runtime.manager.toolSnapshots.first)
        model.setHovering(true)
        XCTAssertTrue(runtime.selectTool(tool))
        let start = Date()
        model.timerTools.selectedMode = .countdown
        model.timerTools.startSelectedTimer(at: start)
        model.timerTools.refresh(at: start.addingTimeInterval(model.timerTools.countdownDuration + 1))
        XCTAssertTrue(model.isTimerCompletionPresented)
        XCTAssertNil(runtime.manager.selectedToolSnapshot)
        XCTAssertFalse(runtime.selectTool(tool))
        XCTAssertEqual(runtime.expandedShellSize.height, IslandVisualStyle.expandedTimerHeight)
        model.acknowledgeTimerCompletion()
    }

    private func hostTool() -> IslandActivity {
        .init(id: "host-test-tool", source: .init(kind: .builtIn, identifier: "host-test-tool"),
              priority: .background, lifecycle: .init(policy: .persistent),
              presentation: .init(title: "Host Test Tool", showsCompact: false, role: .tool), createdAt: Date())
    }

    private func automaticCompactTool() -> IslandActivity {
        .init(id: "host-test-automatic-countdown", source: .init(kind: .builtIn, identifier: "automatic-countdown"),
              priority: .background, lifecycle: .init(policy: .persistent),
              presentation: .init(title: "Automatic Countdown",
                                  compact: .hStack(.init([.icon(.init("timer")), .spacer(.init()), countdownTimeNode()])),
                                  expanded: .vStack(.init([countdownTimeNode(),
                                      .button(.init(actionID: "pause", label: .text(.init("Pause"))))])),
                                  showsCompact: true, role: .tool, compactPolicy: .automatic),
              createdAt: Date(), actions: [.init(id: "pause", title: "Pause")])
    }

    private func countdownTimeNode() -> IslandNode {
        .countdown(.init(id: "focus", generation: "12345678-1234-1234-1234-123456789abc", style: .time))
    }

    private func dispatchTool(_ snapshot: ActivitySnapshot, in runtime: IslandActivityRuntime) -> ActionDispatchResult {
        runtime.router.dispatch(id: snapshot.activity.id, source: snapshot.activity.source,
                                instanceToken: snapshot.instanceToken, action: .init(actionID: "pause", value: .none))
    }

    private func waitForTool(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Tool state did not settle before the deadline.")
    }

    func testProductionRuntimeSharesSchedulerAndShutdownRemovesPendingDeadline() async throws {
        let runtime = IslandActivityRuntime(viewModel: .preview())
        defer { runtime.shutdownPlugins() }
        runtime.pluginScheduler.setPolicy(.active)
        let id = "com.example.production-scheduler"
        let manifest = try PluginManifest(
            id: id, name: "Production Scheduler", version: SemanticVersion("1.0.0"),
            engine: .javaScriptCore, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"),
            permissions: [], capabilities: [.scheduler, .publishActivity]
        )
        let source = """
            function onStart() {
                island.scheduler.requestRefresh(60000).then(() => island.activity.publish({
                    id:'late', presentation:{title:'Late refresh'}
                }));
                island.log('Refresh requested');
            }
            """
        let package = ValidatedPluginPackage(
            manifest: manifest, canonicalRootURL: URL(fileURLWithPath: "/runtime-tests/\(id)", isDirectory: true),
            entryRelativePath: "index.js", entrySource: Data(source.utf8),
            regularFileCount: 2, totalFileBytes: UInt64(source.utf8.count)
        )
        runtime.pluginLifecycle.pluginDidLoad(package, isEnabled: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while runtime.pluginScheduler.snapshot.pendingCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(runtime.pluginLifecycle.allowsExecution(id: id))
        XCTAssertEqual(runtime.pluginScheduler.snapshot.pendingCount, 1)
        XCTAssertEqual(runtime.pluginScheduler.snapshot.timerCount, 1)
        runtime.shutdownPlugins()
        XCTAssertFalse(runtime.pluginLifecycle.allowsExecution(id: id))
        XCTAssertEqual(runtime.pluginScheduler.snapshot.pendingCount, 0)
        XCTAssertEqual(runtime.pluginScheduler.snapshot.timerCount, 0)
        XCTAssertNil(runtime.manager.activity(id: PluginJSBridge.activityID(pluginID: id, localID: "late")))
    }

    func testProductionRuntimeExecutesJavaScriptAndKeepsOtherPluginAdmissionOpen() async throws {
        let runtime = IslandActivityRuntime(viewModel: .preview())
        defer { runtime.pluginLifecycle.shutdown() }
        func package(id: String, source: String) throws -> ValidatedPluginPackage {
            let manifest = try PluginManifest(
                id: id, name: "Production Runtime Test", version: SemanticVersion("1.0.0"),
                engine: .javaScriptCore, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"),
                permissions: [], capabilities: [.publishActivity, .updateActivity, .islandNodeUI]
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
        runtime.pluginLifecycle.pluginDidLoad(try package(id: runningID, source: """
            globalThis.onStart = function() {
                void island.activity.publish({id:'hello', lifecycle:{policy:'progress'},
                    presentation:{title:'Production Bridge',progress:0.1,
                        minimal:{type:'icon',symbolName:'hammer'},
                        expanded:{type:'vStack',children:[{type:'text',content:'Production Bridge'},
                            {type:'progress',value:0.1}]}}})
                    .then(() => island.activity.update({id:'hello',presentation:{title:'Production Build Complete',progress:1,
                        minimal:{type:'icon',symbolName:'checkmark'},
                        expanded:{type:'vStack',children:[{type:'text',content:'Production Build Complete'},
                            {type:'progress',value:1}]}}}))
                    .then(() => island.log('Production Bridge connected'));
            };
            """), isEnabled: true)
        runtime.pluginLifecycle.pluginDidLoad(
            try package(id: failedID, source: "throw new Error('production execution');"), isEnabled: true
        )
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while (runtime.pluginLifecycle.snapshot(id: failedID)?.lastFailure == nil ||
               runtime.pluginBridge.logs(for: runningID).isEmpty), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(runtime.pluginLifecycle.snapshot(id: failedID)?.lastFailure, .startFailed)
        XCTAssertEqual(runtime.pluginLifecycle.snapshot(id: failedID)?.state, .stopped)
        XCTAssertTrue(runtime.pluginLifecycle.allowsExecution(id: runningID))
        let pluginActivity = runtime.manager.activity(id: PluginJSBridge.activityID(pluginID: runningID, localID: "hello"))
        XCTAssertEqual(pluginActivity?.source, .init(kind: .plugin, identifier: runningID))
        XCTAssertEqual(pluginActivity?.presentation.title, "Production Build Complete")
        XCTAssertEqual(pluginActivity?.presentation.progress, 1)
        XCTAssertEqual(pluginActivity?.lifecycle.policy, .progress)
        XCTAssertEqual(pluginActivity?.presentation.minimal, .icon(.init("checkmark")))
        XCTAssertEqual(pluginActivity?.presentation.expanded, .vStack(.init([
            .text(.init("Production Build Complete")), .progress(.init(1))
        ])))
        XCTAssertEqual(runtime.pluginBridge.logs(for: runningID).last?.message, "Plugin log message omitted.")
        runtime.pluginLifecycle.pluginDidChangeEnablement(id: runningID, isEnabled: false)
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
        model.timerTools.selectedMode = .countdown
        model.timerTools.startSelectedTimer(at: completedAt)
        model.timerTools.refresh(
            at: completedAt.addingTimeInterval(model.timerTools.countdownDuration)
        )
        XCTAssertTrue(model.isTimerCompletionPresented)
        XCTAssertEqual(model.timerTools.completedMode, .countdown)
        XCTAssertNil(model.timerTools.runningMode)
        XCTAssertEqual(model.timerTools.countdownRemaining, 0)
        XCTAssertEqual(model.expandedSurface, .tools)
        XCTAssertEqual(model.presentationState, .expanded)

        let runtime = IslandActivityRuntime(viewModel: model)
        defer { runtime.shutdownPlugins() }
        let music = try XCTUnwrap(runtime.manager.currentSnapshot)
        try publishTransientOverride(in: runtime)

        XCTAssertEqual(runtime.manager.current?.id, BatteryActivityProvider.activityID)
        XCTAssertTrue(runtime.prioritizesCurrentActivityOverLegacyContent)
        XCTAssertTrue(model.isTimerCompletionPresented)
        XCTAssertEqual(model.timerTools.completedMode, .countdown)
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
        XCTAssertEqual(model.timerTools.completedMode, .countdown)
        XCTAssertEqual(model.expandedSurface, .tools)
        XCTAssertEqual(model.presentationState, .expanded)

        model.acknowledgeTimerCompletion()
        XCTAssertFalse(model.isTimerCompletionPresented)
        XCTAssertNil(model.timerTools.runningMode)
        XCTAssertNil(model.timerTools.sessionMode)
        XCTAssertNil(model.timerTools.completedMode)
        XCTAssertNil(model.compactTimerMode)
        XCTAssertEqual(model.timerTools.countdownRemaining, model.timerTools.countdownDuration)
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
