import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Vision
import XCTest
@testable import DynamicIsland

/// Exercises the real island and native event dispatcher. These synthetic
/// windows verify controls/layout; they do not claim physical-notch acceptance.
@MainActor
final class IslandToolRegionUITests: XCTestCase {
    func testClockOpensInlineNativeAndPluginTabsAndSwitchesBackWithoutMenuTracking() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        try await clickRegion("island-surface-tools", in: fixture)
        XCTAssertEqual(fixture.model.expandedSurface, .tools)
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        let text = try renderedText(in: fixture)
        for label in ["秒表", "倒计时", "FocusTimer"] {
            XCTAssertTrue(text.contains(label), "Missing inline tab \(label): \(text)")
        }
        XCTAssertFalse(text.contains("QuickTool"), "Other-region plugins must not appear in the timer tabs.")

        try await clickText("倒计时", in: fixture)
        XCTAssertEqual(fixture.model.timerTools.selectedMode, .countdown)
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        try await clickText("FocusTimer", in: fixture)
        XCTAssertEqual(fixture.runtime.manager.selectedToolSnapshot?.activity.id, "region-ui-timer")
        XCTAssertEqual(fixture.runtime.expandedShellSize, CGSize(width: 440, height: 212))
        XCTAssertEqual(ActivityPresentation.HostPolicy.expandedContentHeight(
            forHostShellHeight: Double(fixture.runtime.expandedShellSize.height
                - IslandVisualStyle.expandedToolSelectorHeight - IslandVisualStyle.expandedToolSelectorSpacing)), 134)
        try capture(fixture, name: "Tool-region-timer-plugin-inline")

        try await clickText("秒表", in: fixture)
        XCTAssertEqual(fixture.model.timerTools.selectedMode, .stopwatch)
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(fixture.runtime.expandedShellSize.height, IslandVisualStyle.expandedCompactContentHeight)
        try capture(fixture, name: "Tool-region-native-stopwatch-inline")
        fixture.model.endHovering()
        XCTAssertEqual(fixture.model.presentationState, .compact,
                       "Inline navigation must not install the legacy menu return hold.")
    }

    func testUtilityButtonSelectsItsFirstToolAndClockRestoresNativeTimers() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        try await clickRegion("island-surface-utilities", in: fixture)
        XCTAssertEqual(fixture.model.expandedSurface, .utilities)
        let selected = try XCTUnwrap(fixture.runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(selected.activity.id, "region-ui-utility")
        let utilityText = try renderedText(in: fixture)
        XCTAssertTrue(utilityText.contains("QuickTool"), utilityText)
        XCTAssertTrue(utilityText.contains("Utility body"), utilityText)
        XCTAssertFalse(utilityText.contains("FocusTimer"), utilityText)
        try capture(fixture, name: "Tool-region-utilities-inline")

        try await clickRegion("island-surface-utilities", in: fixture)
        XCTAssertEqual(fixture.runtime.manager.selectedToolSnapshot?.instanceToken, selected.instanceToken,
                       "Clicking the current region must preserve the user's selected tool.")
        try await clickRegion("island-surface-tools", in: fixture)
        XCTAssertEqual(fixture.model.expandedSurface, .tools)
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        XCTAssertTrue(try renderedText(in: fixture).contains("秒表"))
        fixture.model.endHovering()
        XCTAssertEqual(fixture.model.presentationState, .compact)
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        fixture.model.setHovering(true)
        try await settle(fixture)
        XCTAssertEqual(fixture.model.expandedSurface, .tools)
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
    }

    func testSharedPlacementStoreRepartitionsExistingTabsAndEmptyUtilitiesStayUsable() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        try await clickRegion("island-surface-utilities", in: fixture)
        let old = try XCTUnwrap(fixture.runtime.manager.selectedToolSnapshot)
        var handled = 0
        fixture.runtime.router.register(source: old.activity.source) { _ in handled += 1 }
        try fixture.placements.setArea(.timer, forPluginID: "com.example.region-ui-utility")
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(fixture.model.expandedSurface, .utilities)
        XCTAssertEqual(fixture.runtime.router.dispatch(id: old.activity.id, source: old.activity.source,
            instanceToken: old.instanceToken, action: .init(actionID: "run", value: .none)), .inactiveActivity)
        XCTAssertEqual(handled, 0, "Changing placement must never run a plugin action.")
        try await settle(fixture)
        let empty = try renderedText(in: fixture)
        XCTAssertTrue(empty.contains("暂无工具"), empty)
        XCTAssertTrue(empty.contains("打开设置"), empty)
        XCTAssertFalse(empty.contains("QuickTool"), empty)
        XCTAssertEqual(fixture.runtime.expandedShellSize.height, IslandVisualStyle.expandedCompactContentHeight)
        try capture(fixture, name: "Tool-region-empty-utilities")
        try await clickText("打开设置", in: fixture)
        XCTAssertEqual(fixture.settingsRequests, 1)

        try await clickRegion("island-surface-tools", in: fixture)
        let timerText = try renderedText(in: fixture)
        XCTAssertTrue(timerText.contains("FocusTimer") && timerText.contains("QuickTool"), timerText)
        try await clickText("QuickTool", in: fixture)
        XCTAssertEqual(fixture.runtime.manager.selectedToolSnapshot?.instanceToken, old.instanceToken)
        XCTAssertEqual(fixture.model.expandedSurface, .tools)
        try fixture.placements.setArea(.tools, forPluginID: "com.example.region-ui-utility")
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        try await settle(fixture)
        XCTAssertFalse(try renderedText(in: fixture).contains("QuickTool"))
        try await clickRegion("island-surface-utilities", in: fixture)
        XCTAssertEqual(fixture.runtime.manager.selectedToolSnapshot?.instanceToken, old.instanceToken)
        try capture(fixture, name: "Tool-region-live-placement-restored")
    }

    func testThreeControlsPerWingKeepTheCameraGapAcrossDisplayScales() async throws {
        for (width, height, gap, strip) in [(1470.0, 956.0, 179.0, 32.0),
                                           (1280.0, 832.0, 156.0, 28.0),
                                           (2560.0, 1664.0, 312.0, 56.0)] {
            let fixture = try await makeFixture(environment: environment(width: width, height: height,
                                                                         notchWidth: gap, notchHeight: strip))
            defer { fixture.close() }
            let clock = try nativeButton("island-surface-tools", in: fixture.hosting)
            let utilities = try nativeButton("island-surface-utilities", in: fixture.hosting)
            let clockRect = clock.convert(clock.bounds, to: fixture.hosting)
            let utilityRect = utilities.convert(utilities.bounds, to: fixture.hosting)
            let scale = fixture.model.displayLayout.expandedScale
            let leading = (fixture.hosting.bounds.width - IslandVisualStyle.expandedContentSize.width * scale) / 2
                + IslandVisualStyle.expandedContentPadding * scale
            // The native clock is third from the left. The native wrench is
            // third from the right, beside Settings and Quit.
            XCTAssertEqual(clockRect.minX, leading + 2 * (28 + 8) * scale, accuracy: 1)
            XCTAssertEqual(utilityRect.maxX, fixture.hosting.bounds.width - leading - 2 * (28 + 8) * scale, accuracy: 1)
            XCTAssertEqual(clockRect.width, 28 * scale, accuracy: 1)
            XCTAssertEqual(utilityRect.width, 28 * scale, accuracy: 1)
            let cameraLeft = fixture.hosting.bounds.midX - gap / 2
            let cameraRight = fixture.hosting.bounds.midX + gap / 2
            XCTAssertLessThanOrEqual(clockRect.maxX, cameraLeft + 1)
            XCTAssertGreaterThanOrEqual(utilityRect.minX, cameraRight - 1)
            XCTAssertNil(clock.menu)
            XCTAssertNil(utilities.menu)
            XCTAssertTrue(clock.isEnabled && utilities.isEnabled)
            try capture(fixture, name: "Tool-region-three-controls-per-wing-\(Int(width))")
            try await clickRegion("island-surface-tools", in: fixture)
            XCTAssertEqual(fixture.model.expandedSurface, .tools)
            try await clickRegion("island-surface-utilities", in: fixture)
            XCTAssertEqual(fixture.model.expandedSurface, .utilities)
            fixture.model.endHovering()
            XCTAssertEqual(fixture.model.presentationState, .compact)
        }
    }

    func testLongToolListScrollsHorizontallyAndKeepsTheFarTabSelectable() async throws {
        let fixture = try await makeFixture(extraUtilityTools: 12)
        defer { fixture.close() }
        try await clickRegion("island-surface-utilities", in: fixture)
        let scroll = try XCTUnwrap(scrollViews(in: fixture.hosting).first {
            ($0.documentView?.bounds.width ?? 0) > $0.contentView.bounds.width + 40
        }, "An overflowing inline tab row must use a horizontal scroll viewport.")
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.width, scroll.contentView.bounds.width)
        XCTAssertLessThanOrEqual(scroll.bounds.height, 26 * fixture.model.displayLayout.expandedScale + 1)
        let previousOrigin = scroll.contentView.bounds.origin
        scroll.contentView.scroll(to: CGPoint(x: max(0, document.bounds.width - scroll.contentView.bounds.width),
                                             y: previousOrigin.y))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(fixture)
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, previousOrigin.x)
        try capture(fixture, name: "Tool-region-horizontal-overflow-last-tab")
        // Source ordering places QuickTool after all twelve overflow tools.
        try await clickText("QuickTool", in: fixture)
        XCTAssertEqual(fixture.runtime.manager.selectedToolSnapshot?.activity.id, "region-ui-utility")
        XCTAssertEqual(fixture.model.expandedSurface, .utilities)
        XCTAssertEqual(fixture.runtime.expandedShellSize.height, 212)
        fixture.model.endHovering()
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(fixture.model.presentationState, .compact)
    }

    private func makeFixture(environment: ScreenEnvironment? = nil,
                             extraUtilityTools: Int = 0) async throws -> ToolRegionWindowFixture {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session["CGSSessionScreenIsLocked"] as? Bool == true {
            throw XCTSkip("Native input fixtures require an unlocked macOS session.")
        }
        let fixture = try ToolRegionWindowFixture(environment: environment ?? self.environment(
            width: 2560, height: 1664, notchWidth: 312, notchHeight: 56), extraUtilityTools: extraUtilityTools)
        do {
            try await settle(fixture)
            NSApp.activate()
            fixture.panel.makeKeyAndOrderFront(nil)
            try await waitUntil { fixture.panel.isKeyWindow }
            return fixture
        } catch {
            if !fixture.panel.isKeyWindow { NativeWindowTestingDiagnostics.keyTimeout(fixture.panel) }
            fixture.close()
            throw error
        }
    }

    private func nativeButton(_ identifier: String, in view: NSView) throws -> IslandRegionButton.NativeButton {
        func find(_ view: NSView) -> IslandRegionButton.NativeButton? {
            if let button = view as? IslandRegionButton.NativeButton, button.identifier?.rawValue == identifier {
                return button
            }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(find(view), "Missing actual region button \(identifier)")
    }

    private func clickRegion(_ identifier: String, in fixture: ToolRegionWindowFixture) async throws {
        let button = try nativeButton(identifier, in: fixture.hosting)
        XCTAssertNil(button.menu)
        XCTAssertTrue(button.isEnabled)
        let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: fixture.hosting)
        let hit = fixture.hosting.hitTest(try XCTUnwrap(fixture.hosting.superview).convert(point, from: fixture.hosting))
        XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true)
        try await click(point, in: fixture)
    }

    private func clickText(_ label: String, in fixture: ToolRegionWindowFixture) async throws {
        let matches = try recognizedText(in: fixture).compactMap { observation -> CGRect? in
            guard let candidate = observation.topCandidates(1).first,
                  let range = candidate.string.range(of: label),
                  let bounds = try? candidate.boundingBox(for: range) else { return nil }
            return bounds.boundingBox
        }
        // The tab row is above any tool body repeating its name. Use the
        // highest rendered label, and derive the native click from its pixels.
        let text = try renderedText(in: fixture)
        let bounds = try XCTUnwrap(matches.max { $0.midY < $1.midY },
                                   "Missing rendered clickable label \(label): \(text)")
        let point = CGPoint(x: bounds.midX * fixture.hosting.bounds.width,
            y: (fixture.hosting.isFlipped ? 1 - bounds.midY : bounds.midY) * fixture.hosting.bounds.height)
        try await click(point, in: fixture)
    }

    private func click(_ point: CGPoint, in fixture: ToolRegionWindowFixture) async throws {
        fixture.panel.makeKeyAndOrderFront(nil)
        try await waitUntil {
            if !fixture.panel.isKeyWindow { fixture.panel.makeKey() }
            return fixture.panel.isKeyWindow
        }
        let location = fixture.hosting.convert(point, to: nil)
        let events = try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(events[1], atStart: true)
        NSApp.sendEvent(events[0])
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                    inMode: .eventTracking, dequeue: true) { NSApp.sendEvent(up) }
        try await settle(fixture)
    }

    private func settle(_ fixture: ToolRegionWindowFixture) async throws {
        try await Task.sleep(for: .milliseconds(220))
        fixture.hosting.layoutSubtreeIfNeeded()
        fixture.hosting.displayIfNeeded()
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ToolRegionUITestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func bitmap(in fixture: ToolRegionWindowFixture) throws -> NSBitmapImageRep {
        let view = fixture.hosting
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let size = view.bounds.size
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width)), pixelsHigh: Int(ceil(size.height)), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func recognizedText(in fixture: ToolRegionWindowFixture) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        request.customWords = ["FocusTimer", "QuickTool"] + (1...12).map { String(format: "Tool%02d", $0) }
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap(in: fixture).cgImage), options: [:]).perform([request])
        return request.results ?? []
    }

    private func renderedText(in fixture: ToolRegionWindowFixture) throws -> String {
        try recognizedText(in: fixture).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func capture(_ fixture: ToolRegionWindowFixture, name: String) throws {
        let data = try XCTUnwrap(bitmap(in: fixture).representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func environment(width: CGFloat, height: CGFloat,
                             notchWidth: CGFloat, notchHeight: CGFloat) -> ScreenEnvironment {
        let side = (width - notchWidth) / 2
        return ScreenEnvironment(displayID: 1, name: "Tool Region Synthetic Display",
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            visibleFrame: CGRect(x: 0, y: 0, width: width, height: height - notchHeight),
            safeAreaInsets: .init(top: notchHeight),
            auxiliaryTopLeftArea: CGRect(x: 0, y: height - notchHeight, width: side, height: notchHeight),
            auxiliaryTopRightArea: CGRect(x: side + notchWidth, y: height - notchHeight, width: side, height: notchHeight),
            backingScaleFactor: 2, isBuiltIn: true)
    }
}

@MainActor
private final class ToolRegionWindowFixture {
    let model: IslandViewModel
    let placements: PluginToolPlacementStore
    let runtime: IslandActivityRuntime
    let hosting: NSHostingView<AnyView>
    let panel: NSPanel
    private let witness: ToolRegionSettingsWitness
    var settingsRequests: Int { witness.settingsRequests }

    init(environment: ScreenEnvironment, extraUtilityTools: Int) throws {
        placements = PluginToolPlacementStore()
        try placements.setArea(.timer, forPluginID: "com.example.region-ui-timer")
        model = IslandViewModel.preview()
        model.setScreenEnvironment(environment)
        model.setHovering(true)
        runtime = IslandActivityRuntime(viewModel: model, toolPlacements: placements)
        for (id, pluginID, title, body) in [
            ("region-ui-timer", "com.example.region-ui-timer", "FocusTimer", "Timer body"),
            ("region-ui-utility", "com.example.region-ui-utility", "QuickTool", "Utility body")
        ] {
            try Self.publish(id: id, pluginID: pluginID, title: title, body: body, in: runtime)
        }
        for offset in 0..<extraUtilityTools {
            let index = offset + 1
            try Self.publish(id: "region-ui-extra-\(index)", pluginID: "com.example.region-ui-tools",
                title: String(format: "Tool%02d", index), body: "Overflow tool body", in: runtime)
        }
        witness = ToolRegionSettingsWitness()
        let witness = witness
        hosting = NSHostingView(rootView: AnyView(IslandView(viewModel: model, activityRuntime: runtime,
            requestTermination: { XCTFail("Tool region navigation must never activate Quit.") },
            onOpenSettings: { witness.settingsRequests += 1 })
            .environment(\.colorScheme, .dark)
            .transaction { $0.disablesAnimations = true }))
        hosting.frame = CGRect(origin: .zero, size: model.displayLayout.panelSize)
        panel = NSPanel(contentRect: hosting.frame, styleMask: [.titled, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        let container = NSView(frame: hosting.frame)
        panel.contentView = container
        hosting.autoresizingMask = []
        container.addSubview(hosting)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private static func publish(id: String, pluginID: String, title: String, body: String,
                                in runtime: IslandActivityRuntime) throws {
        let source = ActivitySource(kind: .plugin, identifier: pluginID)
        runtime.manager.setPluginSourceEnabled(true, for: source)
        try runtime.manager.publish(.init(id: id, source: source, priority: .background,
            lifecycle: .init(policy: .persistent), presentation: .init(title: title,
                expanded: .text(.init(body)), showsCompact: false, role: .tool), createdAt: Date(),
            actions: [.init(id: "run", title: "Run")]))
    }

    func close() {
        panel.close()
        runtime.shutdownPlugins()
        model.setIslandPanelVisible(false)
    }
}

@MainActor
private final class ToolRegionSettingsWitness { var settingsRequests = 0 }
private enum ToolRegionUITestError: Error { case timedOut }
