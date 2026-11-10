import AppKit
import CoreGraphics
import SwiftUI
import Vision
import XCTest
@testable import DynamicIsland

/// Exercises the official script in a unique package and the complete Host
/// shell. Controlled windows verify fit/input, not physical-device acceptance.
@MainActor
final class PomodoroExpandedShellTests: XCTestCase {
    func testOfficialTimerFitsTightShellWithoutShrinkingControlsOrShowingSettingsCaption() async throws {
        for scale: CGFloat in [0.875, 1, 1.75] {
            let fixture = try ExpandedPomodoroFixture(scale: scale)
            defer { fixture.close() }
            try await fixture.load()
            let mounted = mount(fixture)
            defer { mounted.window.close() }
            for state in ["idle", "running", "paused"] {
                if state == "running" { try await fixture.act("start", suffix: "专注中") }
                if state == "paused" { try await fixture.act("pause", suffix: "已暂停") }
                try await settle(mounted)
                let bitmap = try capture(mounted)
                try assertFit(bitmap, fixture: fixture, name: "\(state)-scale-\(scale)")
                if scale == 1.75 {
                    let text = try recognizedText(bitmap)
                    XCTAssertFalse(text.filter { !$0.isWhitespace }.contains("设置未保存"),
                        "The removed storage caption must not appear inside the shell: \(text)")
                }
            }
        }
    }

    func testTightShellNativeButtonsStillStartPauseResumeStopAndChangePreset() async throws {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session["CGSSessionScreenIsLocked"] as? Bool == true {
            throw XCTSkip("Native mouse delivery requires an unlocked macOS session")
        }
        let fixture = try ExpandedPomodoroFixture(scale: 1)
        defer { fixture.close() }
        try await fixture.load()
        let mounted = mount(fixture, interactive: true)
        defer { mounted.window.close() }
        for (label, suffix) in [("开始", "专注中"), ("暂停", "已暂停"), ("继续", "专注中")] {
            try await settle(mounted)
            let controls = try self.controls(in: capture(mounted), body: bodyRect(fixture), scale: fixture.scale)
            try await click(controls.primary.center, in: mounted)
            try await fixture.wait { fixture.runtime.manager.current?.presentation.subtitle?.hasSuffix(suffix) == true }
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(fixture.runtime.manager.selectedToolSnapshot?.activity.source.identifier, fixture.id,
                "\(label) must preserve the selected plugin instance")
        }
        var controls = try self.controls(in: capture(mounted), body: bodyRect(fixture), scale: fixture.scale)
        try await click(controls.stop.center, in: mounted)
        try await fixture.wait { fixture.runtime.manager.current?.presentation.subtitle == "25 分钟 · 准备专注" }
        try await settle(mounted)
        controls = try self.controls(in: capture(mounted), body: bodyRect(fixture), scale: fixture.scale)
        try await click(controls.increase.center, in: mounted)
        try await fixture.wait { fixture.runtime.manager.current?.presentation.subtitle == "45 分钟 · 准备专注" }
        try await settle(mounted)
        controls = try self.controls(in: capture(mounted), body: bodyRect(fixture), scale: fixture.scale)
        try await click(controls.decrease.center, in: mounted)
        try await fixture.wait { fixture.runtime.manager.current?.presentation.subtitle == "25 分钟 · 准备专注" }
        try assertFit(capture(mounted), fixture: fixture, name: "native-input-completed")
    }

    private func assertFit(_ image: NSBitmapImageRep, fixture: ExpandedPomodoroFixture, name: String) throws {
        let scale = fixture.scale
        XCTAssertEqual(fixture.runtime.expandedShellSize, CGSize(width: 440, height: 174))
        let nativeCountdown = IslandVisualStyle.expandedShellSize(for: .tools, timerMode: .countdown,
            hasTrayItems: false, hasError: false, hasTimerCompletion: false)
        XCTAssertEqual(fixture.runtime.expandedShellSize, nativeCountdown,
            "Pomodoro must use the same shell height as the native countdown")
        let expanded = try XCTUnwrap(fixture.runtime.manager.current?.presentation.expanded)
        XCTAssertFalse(textContents(in: expanded).contains("点击加减切换预设"),
            "The removed preset hint must not consume a row or appear in the rendered tree")
        let shell = try XCTUnwrap(bounds(in: image) { $0.alphaComponent > 0.98 })
        XCTAssertEqual(shell.width / scale, 440, accuracy: 2 / scale, name)
        XCTAssertEqual(shell.height / scale, 174, accuracy: 2 / scale, name)
        let camera = CGRect(x: (fixture.model.displayLayout.panelSize.width - fixture.model.displayLayout.compactSize.width) / 2,
                            y: 0, width: fixture.model.displayLayout.compactSize.width,
                            height: fixture.model.displayLayout.compactSize.height)
        XCTAssertNil(bounds(in: image, rect: camera) {
            $0.alphaComponent > 0.8 && max($0.redComponent, $0.greenComponent, $0.blueComponent) > 0.3
        }, "Header symbols must stay outside the physical camera gap")
        let body = bodyRect(fixture)
        let controls = try self.controls(in: image, body: body, scale: scale)
        for (label, rect) in [("start/pause/resume", controls.primary), ("stop", controls.stop),
                              ("decrease", controls.decrease), ("increase", controls.increase)] {
            XCTAssertTrue(body.insetBy(dx: -2, dy: -2).contains(rect),
                "\(name): \(label) must stay inside the plugin viewport: \(rect), body=\(body)")
        }
        for circle in [controls.primary, controls.stop] {
            XCTAssertEqual(circle.width / scale, 32, accuracy: 2 / scale, "Native timer controls must retain 32 pt size")
            XCTAssertEqual(circle.height / scale, 32, accuracy: 2 / scale)
        }
        let timeRegion = CGRect(x: body.minX, y: body.minY, width: body.width * 0.4, height: body.height)
        let time = try XCTUnwrap(bounds(in: image, rect: timeRegion) {
            $0.alphaComponent > 0.8 && min($0.redComponent, $0.greenComponent, $0.blueComponent) > 0.82
        }, "The complete large time must survive ViewThatFits")
        let reference = try timerReference(fixture)
        XCTAssertEqual(time.height, reference.height, accuracy: 2,
            "Tightening the shell must retain the existing generous Host's timer glyph height")
        XCTAssertEqual(time.width, reference.width, accuracy: 2,
            "The complete timer must not be reduced or clipped to fit the smaller viewport")
        XCTAssertGreaterThan(time.width / scale, 55, "All five timer characters must remain visible")
        let trackRows = (Int(body.minY)..<Int(body.maxY)).filter { y in
            guard let c = image.colorAt(x: Int(body.midX), y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return c.alphaComponent > 0.8 && max(c.redComponent, c.greenComponent, c.blueComponent) > 0.07
        }
        XCTAssertEqual(CGFloat(trackRows.count) / scale, 4, accuracy: 2 / scale,
            "The thin progress track must remain complete inside the smaller shell")
        let warning = CGRect(x: body.minX, y: body.minY + 76 * scale, width: body.width * 0.45,
                             height: body.height - 76 * scale)
        XCTAssertNil(bounds(in: image, rect: warning, matching: warm),
            "Denied storage must not add a yellow caption below the timer")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("di-pomodoro-expanded-shell", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        print("EXPANDED_POMODORO_EVIDENCE=\(directory.path)")
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let boundsText = "\(name): shell=\(shell), time=\(time), generousTimeReference=\(reference), primary=\(controls.primary), stop=\(controls.stop), body=\(body), camera=\(camera), scale=\(scale)"
        try boundsText.write(to: directory.appendingPathComponent(name + ".bounds.txt"), atomically: true, encoding: .utf8)
        let diagnostic = XCTAttachment(string: boundsText)
        diagnostic.name = name + "-bounds"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
    }

    /// Existing generous body budget is the pixel reference for preserving
    /// typography; no font size is inferred from rasterized cap-height.
    private func timerReference(_ fixture: ExpandedPomodoroFixture) throws -> CGRect {
        let snapshot = try XCTUnwrap(fixture.runtime.manager.currentSnapshot)
        let shell = CGSize(width: 428 * fixture.scale, height: 184 * fixture.scale)
        let size = IslandRenderer.contentSize(for: .expanded, shellSize: shell, layoutScale: fixture.scale)
        let hosting = NSHostingView(rootView: AnyView(IslandRenderer(presentation: snapshot.activity.presentation,
            mode: .expanded, shellSize: shell,
            countdownResolver: { fixture.runtime.resolveCountdown($0, for: snapshot) }, isVisible: false)
            .environment(\.colorScheme, .dark).environment(\.islandLayoutScale, fixture.scale)
            .transaction { $0.disablesAnimations = true }))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = hosting
        defer { window.close() }
        let image = try capture(.init(hosting: hosting, window: window))
        return try XCTUnwrap(bounds(in: image, rect: CGRect(x: 0, y: 0, width: size.width * 0.4, height: size.height)) {
            $0.alphaComponent > 0.8 && min($0.redComponent, $0.greenComponent, $0.blueComponent) > 0.82
        })
    }

    private func bodyRect(_ fixture: ExpandedPomodoroFixture) -> CGRect {
        let shellX = (fixture.model.displayLayout.panelSize.width - 440 * fixture.scale) / 2
        return CGRect(x: shellX + 14 * fixture.scale, y: 70 * fixture.scale,
                      width: 412 * fixture.scale, height: 96 * fixture.scale)
    }

    private func mount(_ fixture: ExpandedPomodoroFixture, interactive: Bool = false) -> ExpandedMounted {
        let root = AnyView(IslandView(viewModel: fixture.model, activityRuntime: fixture.runtime)
            .defaultAppStorage(fixture.defaults).environment(\.colorScheme, .dark)
            .transaction { $0.disablesAnimations = true })
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: fixture.model.displayLayout.panelSize)
        let window: NSWindow
        if interactive {
            let panel = NSPanel(contentRect: hosting.frame, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.hidesOnDeactivate = false
            window = panel
        } else {
            window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        }
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = hosting
        if interactive { window.center(); window.makeKeyAndOrderFront(nil) }
        return .init(hosting: hosting, window: window)
    }

    private func settle(_ mounted: ExpandedMounted) async throws {
        try await Task.sleep(for: .milliseconds(180))
        mounted.hosting.layoutSubtreeIfNeeded()
        mounted.hosting.displayIfNeeded()
    }

    private func capture(_ mounted: ExpandedMounted) throws -> NSBitmapImageRep {
        let size = mounted.hosting.bounds.size
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width)),
            pixelsHigh: Int(ceil(size.height)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        image.size = size
        image.bitmapData?.initialize(repeating: 0, count: image.bytesPerRow * image.pixelsHigh)
        mounted.hosting.layoutSubtreeIfNeeded()
        mounted.hosting.displayIfNeeded()
        mounted.hosting.cacheDisplay(in: mounted.hosting.bounds, to: image)
        return image
    }

    private func controls(in image: NSBitmapImageRep, body: CGRect, scale: CGFloat) throws -> ExpandedControls {
        let primary = try XCTUnwrap(circles(in: image, rect: body, scale: scale, matching: tomato)
            .max { $0.width * $0.height < $1.width * $1.height }, "The real tomato-red filled timer control must be painted")
        let neutral = circles(in: image, rect: body, scale: scale) {
            $0.redComponent > 0.015 && abs($0.redComponent - $0.greenComponent) < 0.025
                && abs($0.greenComponent - $0.blueComponent) < 0.025
        }
        let stop = try XCTUnwrap(neutral.filter { abs($0.midY - primary.midY) < 3 * scale && $0.midX < primary.midX }
            .max { $0.midX < $1.midX })
        let adjust = neutral.filter { $0.midY < primary.minY + scale }.sorted { $0.midX < $1.midX }
        XCTAssertEqual(adjust.count, 2, "Both native +/- circles must fit without becoming a summary")
        return .init(primary: primary, stop: stop, decrease: try XCTUnwrap(adjust.first), increase: try XCTUnwrap(adjust.last))
    }

    private func circles(in image: NSBitmapImageRep, rect: CGRect, scale: CGFloat,
                         matching predicate: (NSColor) -> Bool) -> [CGRect] {
        let width = image.pixelsWide, height = image.pixelsHigh
        var mask = [UInt8](repeating: 0, count: width * height)
        for y in max(0, Int(rect.minY))..<min(height, Int(ceil(rect.maxY))) {
            for x in max(0, Int(rect.minX))..<min(width, Int(ceil(rect.maxX))) {
                guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.1, predicate(c) else { continue }
                mask[y * width + x] = 1
            }
        }
        var result: [CGRect] = []
        for start in mask.indices where mask[start] == 1 {
            mask[start] = 0
            var pending = [start], cursor = 0
            var minX = start % width, maxX = minX, minY = start / width, maxY = minY
            while cursor < pending.count {
                let index = pending[cursor], x = index % width, y = index / width
                cursor += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for next in [x > 0 ? index - 1 : -1, x + 1 < width ? index + 1 : -1,
                             y > 0 ? index - width : -1, y + 1 < height ? index + width : -1]
                where next >= 0 && mask[next] == 1 { mask[next] = 0; pending.append(next) }
            }
            let bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            if bounds.width >= 18 * scale, bounds.height >= 18 * scale,
               bounds.width / bounds.height > 0.85, bounds.width / bounds.height < 1.15 { result.append(bounds) }
        }
        return result
    }

    private func textContents(in node: IslandNode) -> [String] {
        switch node {
        case .text(let text): return [text.content]
        case .hStack(let stack), .vStack(let stack), .zStack(let stack):
            return stack.children.flatMap { textContents(in: $0) }
        case .button(let button): return textContents(in: button.label)
        default: return []
        }
    }

    private func tomato(_ c: NSColor) -> Bool {
        c.redComponent > 0.6 && c.greenComponent < 0.55 && c.blueComponent < 0.55
            && c.redComponent > c.greenComponent + 0.2 && c.redComponent > c.blueComponent + 0.2
    }

    private func warm(_ c: NSColor) -> Bool {
        c.redComponent > 0.6 && c.greenComponent > 0.55 && c.greenComponent < 0.95 && c.blueComponent < 0.6
    }

    private func bounds(in image: NSBitmapImageRep, rect: CGRect? = nil,
                        matching predicate: (NSColor) -> Bool) -> CGRect? {
        let region = rect ?? CGRect(x: 0, y: 0, width: image.pixelsWide, height: image.pixelsHigh)
        var result = CGRect.null
        for y in max(0, Int(region.minY))..<min(image.pixelsHigh, Int(ceil(region.maxY))) {
            for x in max(0, Int(region.minX))..<min(image.pixelsWide, Int(ceil(region.maxX))) {
                guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), predicate(c) else { continue }
                result = result.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return result.isNull ? nil : result
    }

    private func recognizedText(_ image: NSBitmapImageRep) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage), options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func click(_ topLeft: CGPoint, in mounted: ExpandedMounted) async throws {
        mounted.window.makeKeyAndOrderFront(nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !mounted.window.isKeyWindow && ContinuousClock.now < deadline {
            mounted.window.makeKey()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(mounted.window.isKeyWindow)
        let point = CGPoint(x: topLeft.x, y: mounted.hosting.isFlipped ? topLeft.y : mounted.hosting.bounds.height - topLeft.y)
        let location = mounted.hosting.convert(point, to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: mounted.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: mounted.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
        if let event = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking, dequeue: true) {
            NSApp.sendEvent(event)
        }
        try await settle(mounted)
    }
}

private struct ExpandedMounted {
    let hosting: NSHostingView<AnyView>
    let window: NSWindow
}

private struct ExpandedControls {
    let primary: CGRect
    let stop: CGRect
    let decrease: CGRect
    let increase: CGRect
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

@MainActor
private final class ExpandedPomodoroFixture {
    let id = "com.example.expanded-shell"
    let model = IslandViewModel.preview()
    let root: URL
    let suite = "ExpandedPomodoroShell.\(UUID().uuidString)"
    let defaults: UserDefaults
    let package: ValidatedPluginPackage
    let runtime: IslandActivityRuntime
    var scale: CGFloat { model.displayLayout.expandedScale }

    init(scale: CGFloat) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("expanded-pomodoro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(IslandAppearance.classic.rawValue, forKey: IslandAppearance.defaultsKey)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/plugin-system/examples/pomodoro")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("manifest.json"))) as? [String: Any])
        manifest["id"] = id
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
        try Data(contentsOf: source.appendingPathComponent("index.js")).write(to: root.appendingPathComponent("index.js"))
        package = try PluginValidator().validateExpandedPackage(at: root,
            context: .init(hostVersion: SemanticVersion("0.6.1"), occupiedPluginIDs: [], allowedContainerURL: root.deletingLastPathComponent()))
        let placements = PluginToolPlacementStore()
        try placements.setArea(.timer, forPluginID: id)
        runtime = IslandActivityRuntime(viewModel: model, toolPlacements: placements)
        let review = runtime.permissionManager.request(package: package)
        try runtime.permissionManager.applyHostDecision(decision: .denied, review: review, permission: .localStorage)
        let screenWidth: CGFloat = 1600, screenHeight: CGFloat = 1000
        let height = 32 * scale, gap = 179 * scale, side = (screenWidth - gap) / 2
        model.setScreenEnvironment(.init(displayID: 19, name: "Expanded timer probe",
            frame: CGRect(x: 0, y: 0, width: screenWidth, height: screenHeight),
            visibleFrame: CGRect(x: 0, y: 0, width: screenWidth, height: screenHeight - height), safeAreaInsets: .init(top: height),
            auxiliaryTopLeftArea: CGRect(x: 0, y: screenHeight - height, width: side, height: height),
            auxiliaryTopRightArea: CGRect(x: side + gap, y: screenHeight - height, width: side, height: height),
            backingScaleFactor: 1, isBuiltIn: true))
    }

    func load() async throws {
        runtime.pluginLifecycle.pluginDidLoad(package, isEnabled: true)
        try await wait { self.runtime.manager.toolSnapshots.contains { $0.activity.source.identifier == self.id } }
        model.setHovering(true)
        XCTAssertTrue(runtime.selectTool(try XCTUnwrap(runtime.manager.toolSnapshots.first { $0.activity.source.identifier == id })))
        try await wait { self.runtime.manager.current?.presentation.subtitle == "25 分钟 · 准备专注" }
        try await Task.sleep(for: .milliseconds(50))
    }

    func act(_ actionID: String, suffix: String) async throws {
        let snapshot = try XCTUnwrap(runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(runtime.router.dispatch(id: snapshot.activity.id, source: snapshot.activity.source,
            instanceToken: snapshot.instanceToken, action: .init(actionID: actionID, value: .none)), .handled)
        try await wait { self.runtime.manager.current?.presentation.subtitle?.hasSuffix(suffix) == true }
        try await Task.sleep(for: .milliseconds(50))
    }

    func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Official expanded Pomodoro state did not settle: \(String(describing: runtime.manager.current?.presentation.subtitle))")
                throw ExpandedFixtureError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func close() {
        runtime.shutdownPlugins()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private enum ExpandedFixtureError: Error { case timeout }
}
