import AppKit
import SwiftUI
import XCTest
@testable import DynamicIsland

/// Uses the native page monitors as the gesture transport, without synthesizing
/// scroll events or depending on OCR for navigation state.
@MainActor
final class IslandLayerPagingTests: XCTestCase {
    func testHomeContentMonitorLoopsThroughAllFourLayersWithoutChangingRegions() async throws {
        let fixture = try LayerPagingFixture()
        defer { fixture.close() }
        try await settle(fixture)
        for layer in [IslandHomeLayer.calendar, .courses, .meetings, .music, .calendar] {
            try await pageContent(1, fixture)
            XCTAssertEqual(fixture.model.homeLayer, layer)
            XCTAssertEqual(fixture.model.expandedSurface, .music)
        }
        for layer in [IslandHomeLayer.music, .meetings, .courses, .calendar, .music] {
            try await pageContent(-1, fixture)
            XCTAssertEqual(fixture.model.homeLayer, layer)
            XCTAssertEqual(fixture.model.expandedSurface, .music)
        }
        XCTAssertNil(fixture.model.timerTools.runningMode)
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
    }

    func testTimerPagingIncludesNativeModesAndPlacedPluginsWithoutRunningActions() async throws {
        let fixture = try LayerPagingFixture()
        defer { fixture.close() }
        fixture.runtime.selectLegacySurface(.tools)
        try await settle(fixture)
        XCTAssertEqual(fixture.model.timerTools.selectedMode, .stopwatch)
        let timerTools = fixture.runtime.toolSnapshots(in: .timer)
        XCTAssertEqual(timerTools.count, 2)
        var actions = 0
        for tool in timerTools { fixture.runtime.router.register(source: tool.activity.source) { _ in actions += 1 } }

        try await pageContent(1, fixture)
        XCTAssertEqual(fixture.model.timerTools.selectedMode, .countdown)
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        for tool in timerTools {
            try await pageContent(1, fixture)
            XCTAssertEqual(fixture.runtime.manager.selectedToolSnapshot?.instanceToken, tool.instanceToken)
        }
        try await pageContent(1, fixture)
        XCTAssertEqual(fixture.runtime.manager.selectedToolSnapshot?.instanceToken, timerTools.last?.instanceToken,
                       "The last page must not wrap to the first native timer.")
        for _ in timerTools { try await pageContent(-1, fixture) }
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(fixture.model.timerTools.selectedMode, .countdown)
        try await pageContent(-1, fixture)
        try await pageContent(-1, fixture)
        XCTAssertEqual(fixture.model.timerTools.selectedMode, .stopwatch)
        XCTAssertNil(fixture.model.timerTools.runningMode)
        XCTAssertEqual(actions, 0, "Paging selects a tool; it must never execute that tool's action.")
    }

    func testUtilityPagingAndOverflowStripKeepDistinctGestureTargets() async throws {
        let fixture = try LayerPagingFixture(extraUtilities: 10)
        defer { fixture.close() }
        let tools = fixture.runtime.toolSnapshots(in: .tools)
        XCTAssertTrue(fixture.runtime.selectTool(try XCTUnwrap(tools.first)))
        try await settle(fixture)
        var monitor = try contentMonitor(fixture)
        XCTAssertTrue(monitor.exclusionRects.contains { $0.width > 150 * fixture.scale && $0.height >= 20 * fixture.scale },
                      "The overflowing tab strip must keep its native horizontal scrolling.")
        for rect in monitor.exclusionRects {
            let point = monitor.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
            XCTAssertFalse(monitor.isGestureEligible(at: point, in: fixture.panel))
        }
        for tool in tools.dropFirst() {
            try await pageContent(1, fixture)
            XCTAssertEqual(fixture.runtime.manager.selectedToolSnapshot?.instanceToken, tool.instanceToken)
            XCTAssertEqual(fixture.model.expandedSurface, .utilities)
        }
        try await pageContent(1, fixture)
        XCTAssertEqual(fixture.runtime.manager.selectedToolSnapshot?.instanceToken, tools.last?.instanceToken)
        for _ in tools.dropFirst() { try await pageContent(-1, fixture) }
        XCTAssertEqual(fixture.runtime.manager.selectedToolSnapshot?.instanceToken, tools.first?.instanceToken)
        monitor = try contentMonitor(fixture)
        let body = monitor.convert(CGPoint(x: monitor.bounds.midX, y: monitor.bounds.maxY - 10 * fixture.scale), to: nil)
        XCTAssertTrue(monitor.isGestureEligible(at: body, in: fixture.panel))
    }

    func testRegionToolbarAndInnerPageMonitorsDoNotOverlap() async throws {
        let fixture = try LayerPagingFixture()
        defer { fixture.close() }
        try await settle(fixture)
        let toolbar = try toolbarMonitor(fixture)
        let stableContent = try contentMonitor(fixture)
        for expected in [IslandExpandedSurface.fileTray, .tools, .utilities] {
            toolbar.onStep?(1)
            try await settle(fixture)
            XCTAssertEqual(fixture.model.expandedSurface, expected)
            XCTAssertTrue(try contentMonitor(fixture) === stableContent,
                          "Region changes must retain the one inner-page gesture state machine.")
        }
        toolbar.onStep?(1)
        try await settle(fixture)
        XCTAssertEqual(fixture.model.expandedSurface, .utilities)
        let content = try contentMonitor(fixture)
        let toolbarPoint = toolbar.convert(CGPoint(x: toolbar.bounds.midX, y: toolbar.bounds.midY), to: nil)
        let contentPoint = content.convert(CGPoint(x: content.bounds.midX, y: content.bounds.maxY - 5), to: nil)
        XCTAssertTrue(toolbar.isGestureEligible(at: toolbarPoint, in: fixture.panel))
        XCTAssertFalse(content.isGestureEligible(at: toolbarPoint, in: fixture.panel))
        XCTAssertFalse(toolbar.isGestureEligible(at: contentPoint, in: fixture.panel))
        for expected in [IslandExpandedSurface.tools, .fileTray, .music] {
            toolbar.onStep?(-1)
            try await settle(fixture)
            XCTAssertEqual(fixture.model.expandedSurface, expected)
            XCTAssertTrue(try contentMonitor(fixture) === stableContent)
        }
        toolbar.onStep?(-1)
        XCTAssertEqual(fixture.model.expandedSurface, .music)
        XCTAssertEqual(fixture.model.homeLayer, .music, "Region navigation must not also step the home layer.")
    }

    func testRetainedToolCallbackCannotNavigateAfterDragHideLockCompletionOrCriticalStatus() async throws {
        let fixture = try LayerPagingFixture()
        defer { fixture.close() }
        fixture.runtime.selectLegacySurface(.tools)
        try await settle(fixture)
        let stale = try contentMonitor(fixture)
        fixture.model.setDragging(true)
        stale.onStep?(1)
        XCTAssertEqual(fixture.model.expandedSurface, .fileTray)
        XCTAssertEqual(fixture.model.timerTools.selectedMode, .stopwatch)
        fixture.model.setDragging(false)
        fixture.runtime.selectLegacySurface(.tools)
        fixture.model.setIslandPanelVisible(false)
        stale.onStep?(1)
        XCTAssertEqual(fixture.model.timerTools.selectedMode, .stopwatch)
        fixture.model.setIslandPanelVisible(true)
        fixture.model.toggleFileTrayLock()
        stale.onStep?(1)
        XCTAssertEqual(fixture.model.timerTools.selectedMode, .stopwatch)
        fixture.model.toggleFileTrayLock()
        let start = Date()
        fixture.model.timerTools.selectedMode = .countdown
        fixture.model.timerTools.startSelectedTimer(at: start)
        fixture.model.timerTools.refresh(at: start.addingTimeInterval(fixture.model.timerTools.countdownDuration))
        XCTAssertTrue(fixture.model.isTimerCompletionPresented)
        stale.onStep?(-1)
        XCTAssertEqual(fixture.model.timerTools.selectedMode, .countdown)
        fixture.model.acknowledgeTimerCompletion()
        fixture.model.setHovering(false)
        fixture.model.setHovering(true)
        fixture.runtime.selectLegacySurface(.tools)
        fixture.model.timerTools.selectedMode = .stopwatch
        XCTAssertEqual(fixture.model.presentationState, .expanded)
        try fixture.runtime.manager.publish(.init(id: "layer-critical", source: .init(kind: .builtIn, identifier: "layer-critical"),
            priority: .critical, lifecycle: .init(policy: .critical), presentation: .init(title: "Critical status"), createdAt: Date()))
        stale.onStep?(1)
        XCTAssertEqual(fixture.model.timerTools.selectedMode, .stopwatch)
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
    }

    private func pageContent(_ offset: Int, _ fixture: LayerPagingFixture) async throws {
        let stableMonitor = try contentMonitor(fixture)
        stableMonitor.onStep?(offset)
        try await settle(fixture)
        XCTAssertTrue(try contentMonitor(fixture) === stableMonitor,
                      "A tool transition must not replace the monitor and reset an in-progress gesture.")
        XCTAssertEqual(monitors(fixture.hosting).filter {
            $0.isPagingEnabled && $0.bounds.height > 40 * fixture.scale
        }.count, 1, "Only one inner-page monitor may observe the gesture.")
    }

    private func contentMonitor(_ fixture: LayerPagingFixture) throws -> IslandHomeScrollMonitorView {
        try XCTUnwrap(monitors(fixture.hosting).filter { $0.isPagingEnabled && $0.bounds.height > 40 * fixture.scale }
            .max { $0.bounds.height < $1.bounds.height }, "Expected one active inner-page monitor.")
    }

    private func toolbarMonitor(_ fixture: LayerPagingFixture) throws -> IslandHomeScrollMonitorView {
        try XCTUnwrap(monitors(fixture.hosting).first {
            $0.isPagingEnabled && $0.bounds.height <= 32 * fixture.scale && $0.bounds.width > 200 * fixture.scale
        }, "Expected the disjoint region toolbar monitor.")
    }

    private func monitors(_ view: NSView) -> [IslandHomeScrollMonitorView] {
        ((view as? IslandHomeScrollMonitorView).map { [$0] } ?? [])
            + view.subviews.flatMap { monitors($0) }
    }

    private func settle(_ fixture: LayerPagingFixture) async throws {
        try await Task.sleep(for: .milliseconds(400))
        fixture.hosting.layoutSubtreeIfNeeded()
        fixture.hosting.displayIfNeeded()
    }
}

@MainActor
private final class LayerPagingFixture {
    let model: IslandViewModel
    let runtime: IslandActivityRuntime
    let hosting: NSHostingView<AnyView>
    let panel: NSPanel
    let defaults: UserDefaults
    let suite = "IslandLayerPagingTests.\(UUID().uuidString)"
    var scale: CGFloat { model.displayLayout.expandedScale }

    init(extraUtilities: Int = 0) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let placements = PluginToolPlacementStore()
        for id in ["com.example.layer-timer-a", "com.example.layer-timer-b"] { try placements.setArea(.timer, forPluginID: id) }
        model = IslandViewModel(volumeService: LayerPagingVolumeService(), fileTrayService: LayerPagingFileTrayService(),
            sharingService: LayerPagingSharingService(), musicService: PlaceholderMusicControlService(),
            hapticFeedbackService: LayerPagingHapticService(), homeSettings: IslandHomeSettings(defaults: defaults))
        model.setHovering(true)
        runtime = IslandActivityRuntime(viewModel: model, toolPlacements: placements)
        let specs = [("timer-a", "com.example.layer-timer-a"), ("timer-b", "com.example.layer-timer-b"),
                     ("utility-a", "com.example.layer-utility-a"), ("utility-b", "com.example.layer-utility-b")]
            + (0..<extraUtilities).map { ("overflow-\($0)", "com.example.layer-overflow") }
        for (index, spec) in specs.enumerated() {
            let source = ActivitySource(kind: .plugin, identifier: spec.1)
            runtime.manager.setPluginSourceEnabled(true, for: source)
            try runtime.manager.publish(.init(id: spec.0, source: source, priority: .background,
                lifecycle: .init(policy: .persistent), presentation: .init(title: "Layer \(index)",
                    expanded: .text(.init("Layer body \(index)")), showsCompact: false, role: .tool),
                createdAt: Date().addingTimeInterval(Double(index) / 100), actions: [.init(id: "run", title: "Run")]))
        }
        hosting = NSHostingView(rootView: AnyView(IslandView(viewModel: model, activityRuntime: runtime,
            requestTermination: { XCTFail("Paging must not quit the app.") }).transaction { $0.disablesAnimations = true }))
        hosting.frame = CGRect(origin: .zero, size: model.displayLayout.panelSize)
        panel = NSPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        panel.center()
        panel.orderFrontRegardless()
    }

    func close() {
        panel.close()
        runtime.shutdownPlugins()
        model.setIslandPanelVisible(false)
        defaults.removePersistentDomain(forName: suite)
    }
}

private struct LayerPagingVolumeService: VolumeService {
    func currentVolume() throws -> Float { 0.5 }
    func setVolume(_ volume: Float) throws {}
}

private struct LayerPagingFileTrayService: FileTrayService {
    func importFiles(from urls: [URL]) throws -> [TrayFileItem] { [] }
    func clear() throws {}
    func remove(_ item: TrayFileItem) throws {}
}

private struct LayerPagingSharingService: SharingService {
    func share(urls: [URL]) throws {}
}

private struct LayerPagingHapticService: HapticFeedbackService {
    func performExpansionFeedback() {}
}
