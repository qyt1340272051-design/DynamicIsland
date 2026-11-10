import AppKit
import CoreGraphics
import SwiftUI
import Vision
import XCTest
@testable import DynamicIsland

/// Exercises the official JavaScript package through the real Host renderer.
/// The controlled windows verify native layout/input, not physical-device fit.
@MainActor
final class PomodoroNativeLayoutTests: XCTestCase {
    func testOfficialIdleRunningAndPausedControlsFitNativeAndInlineHostBudgets() async throws {
        let fixture = try await readyFixture()
        defer { fixture.shutdown() }

        for state in ["idle", "running", "paused"] {
            if state == "running" {
                try fixture.act("start")
                try await fixture.waitForState("专注中")
                fixture.clock.now += .seconds(15)
            } else if state == "paused" {
                try fixture.act("pause")
                try await fixture.waitForState("已暂停")
            }
            XCTAssertFalse(fixture.hasUnsavedSettingsHint)
            let presentation = try XCTUnwrap(fixture.tool?.presentation)
            let expanded = try XCTUnwrap(presentation.expanded)
            XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(expanded, for: .expanded))
            XCTAssertEqual(IslandRenderer.resolvedNode(in: presentation, for: .expanded), expanded)
            XCTAssertFalse(textContents(in: expanded).contains("点击加减切换预设"))

            for scale: CGFloat in [0.88, 1, 1.54] {
                let expectedBody = CGSize(width: 412 * scale, height: 96 * scale)
                let renderShell = CGSize(width: 428 * scale, height: 146 * scale)
                let actualBody = IslandRenderer.contentSize(for: .expanded, shellSize: renderShell, layoutScale: scale)
                XCTAssertEqual(actualBody.width, expectedBody.width, accuracy: 0.001)
                XCTAssertEqual(actualBody.height, expectedBody.height, accuracy: 0.001)
                let outerShell = IslandVisualStyle.expandedShellSize(for: .tools, timerMode: .countdown,
                    hasTrayItems: false, hasError: false, hasTimerCompletion: false, hasPresentedTool: true)
                XCTAssertEqual(outerShell.height, 212)
                XCTAssertEqual(outerShell.height - IslandVisualStyle.expandedToolSelectorHeight
                    - IslandVisualStyle.expandedToolSelectorSpacing, 184)

                for inline in [false, true] {
                    let mounted = try mountPlugin(fixture, scale: scale, inline: inline)
                    defer { mounted.close() }
                    try await settle(mounted)
                    let bitmap = try capture(mounted)
                    let name = "pomodoro-\(state)-\(inline ? "inline-174" : "body-96")-scale-\(scaleName(scale))"
                    try attach(bitmap, name: name)
                    let body = bodyRect(scale: scale, inline: inline)
                    let primary = state == "running" ? "暂停" : state == "paused" ? "继续" : "开始"
                    let controls = try renderedControls(in: bitmap, body: body, scale: scale)
                    for label in ["减少专注时长", "增加专注时长", "结束", primary] {
                        let rect = controls.frame(for: label)
                        XCTAssertTrue(body.insetBy(dx: -1, dy: -1).contains(rect),
                                      "\(name): \(label) clips outside the Host body: \(rect), body=\(body)")
                        XCTAssertGreaterThan(rect.width, 18 * scale, "\(name): real controls must survive ViewThatFits.")
                        if label.contains("专注时长") {
                            let brightness = backgroundBrightness(in: bitmap, circle: rect)
                            if state == "running" {
                                XCTAssertLessThan(brightness, 0.05, "\(name): \(label) must be visibly disabled.")
                            } else {
                                XCTAssertGreaterThan(brightness, 0.05, "\(name): \(label) must be visibly enabled.")
                            }
                        }
                    }
                    let primaryRect = controls.primary
                    XCTAssertEqual(primaryRect.width, 32 * scale, accuracy: 2, "\(name): native control width")
                    XCTAssertEqual(primaryRect.height, 32 * scale, accuracy: 2, "\(name): native control height")
                    XCTAssertGreaterThan(primaryRect.midX, body.minX + body.width * 0.65,
                                         "\(name): the native controls must remain to the right of the time.")
                    XCTAssertGreaterThan(tomatoPixels(in: bitmap, rect: primaryRect), Int(180 * scale * scale),
                                         "\(name): the primary action must keep its tomato-red filled timer tint.")
                    if !inline {
                        let text = try renderedText(in: bitmap)
                        XCTAssertTrue(text.contains(state == "idle" ? "25:00" : "24:45"),
                                      "\(name): all five timer characters must be painted; OCR=\(text)")
                        let whiteTime = try XCTUnwrap(whiteTimeBounds(in: bitmap, rect: timeRect(in: body)))
                        XCTAssertGreaterThan(whiteTime.height, 15 * scale, "\(name): time was reduced to caption size.")
                        XCTAssertLessThan(whiteTime.maxY, expectedBody.height - 4 * scale,
                                          "\(name): the timer digits must fit above the progress track.")
                        XCTAssertEqual(Double(trackRowsAtCenter(in: bitmap)), Double(4 * scale), accuracy: 2,
                                       "\(name): the progress track must keep the built-in timer's 4-point footprint.")
                    }
                }
            }
        }
        fixture.assertNoFailures()
    }

    func testIdleTimeAndPrimaryControlMatchBuiltInTimerAtEveryHostScale() async throws {
        let fixture = try await readyFixture()
        defer { fixture.shutdown() }
        let native = IslandTimerToolsModel()
        native.selectedMode = .countdown
        native.adjustCountdownMinutes(by: 20)
        XCTAssertEqual(native.formattedDisplayedTime, "25:00")

        for scale: CGFloat in [0.88, 1, 1.54] {
            let plugin = try mountPlugin(fixture, scale: scale)
            let builtIn = mount(AnyView(IslandTimerToolsView(model: native, showsModePicker: false,
                onAcknowledgeCompletion: {}).environment(\.islandLayoutScale, scale)
                .environment(\.colorScheme, .dark).foregroundStyle(.white)),
                size: CGSize(width: 412 * scale, height: 96 * scale))
            defer { plugin.close(); builtIn.close() }
            try await settle(plugin)
            try await settle(builtIn)
            let pluginBitmap = try capture(plugin)
            let nativeBitmap = try capture(builtIn)
            try attach(pluginBitmap, name: "pomodoro-typography-reference-scale-\(scaleName(scale))")
            try attach(nativeBitmap, name: "built-in-countdown-reference-scale-\(scaleName(scale))")
            let body = bodyRect(scale: scale, inline: false)
            let pluginTime = try XCTUnwrap(whiteTimeBounds(in: pluginBitmap, rect: timeRect(in: body)))
            let nativeTime = try XCTUnwrap(whiteTimeBounds(in: nativeBitmap, rect: timeRect(in: body)))
            XCTAssertEqual(pluginTime.height, nativeTime.height, accuracy: 1.5,
                           "scale=\(scale): the plugin must use the built-in 26-point timer typography.")
            XCTAssertEqual(pluginTime.width, nativeTime.width, accuracy: 2,
                           "scale=\(scale): 25:00 must preserve the same monospaced digit footprint.")
            let pluginButton = try renderedControls(in: pluginBitmap, body: body, scale: scale).primary
            let nativeButton = try renderedControls(in: nativeBitmap, body: body, scale: scale, redPrimary: false).primary
            XCTAssertEqual(pluginButton.width, nativeButton.width, accuracy: 1)
            XCTAssertEqual(pluginButton.height, nativeButton.height, accuracy: 1)
        }
    }

    func testDeniedStorageDoesNotAddCaptionOrClipNativeControls() async throws {
        let fixture = try PomodoroPluginFixture()
        defer { fixture.shutdown() }
        try await fixture.load()
        XCTAssertFalse(fixture.hasUnsavedSettingsHint)
        for scale: CGFloat in [0.88, 1, 1.54] {
            let mounted = try mountPlugin(fixture, scale: scale)
            defer { mounted.close() }
            try await settle(mounted)
            let body = bodyRect(scale: scale, inline: false)
            let bitmap = try capture(mounted)
            try attach(bitmap, name: "pomodoro-no-settings-caption-scale-\(scaleName(scale))")
            let controls = try renderedControls(in: bitmap, body: body, scale: scale)
            for label in ["减少专注时长", "增加专注时长", "结束", "开始"] {
                XCTAssertTrue(body.insetBy(dx: -1, dy: -1).contains(controls.frame(for: label)))
            }
            XCTAssertEqual(Double(trackRowsAtCenter(in: bitmap)), Double(4 * scale), accuracy: 2)
            let warningRegion = CGRect(x: 0, y: controls.primary.maxY + 8 * scale,
                                       width: body.width * 0.45, height: body.height - controls.primary.maxY - 8 * scale)
            XCTAssertEqual(warmPixels(in: bitmap, rect: warningRegion), 0,
                           "Storage status must not add a yellow caption below the progress track.")
            if scale > 1.5 {
                let recognized = try renderedText(in: bitmap, languages: ["zh-Hans", "en-US"])
                XCTAssertFalse(recognized.filter { !$0.isWhitespace }.contains("设置未保存"),
                               "The removed caption must not be rendered; OCR=\(recognized)")
            }
        }
        fixture.assertNoFailures()
    }

    func testNativeMouseInputStartsPausesResumesAndPreservesAllPresetChoices() async throws {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session["CGSSessionScreenIsLocked"] as? Bool == true {
            throw XCTSkip("Native mouse delivery requires an unlocked macOS session.")
        }
        let fixture = try await readyFixture()
        defer { fixture.shutdown() }
        let actions = PomodoroNativeActionCapture()
        let mounted = try mountPlugin(fixture, scale: 1, interactive: true, actions: actions)
        defer { mounted.close() }
        try await settle(mounted)

        try await click("开始", in: mounted)
        try await fixture.waitForState("专注中")
        XCTAssertEqual(actions.ids, ["start"])
        fixture.clock.now += .seconds(15)
        try await updatePlugin(mounted, fixture: fixture, scale: 1, actions: actions)
        try await settle(mounted)
        let generation = try XCTUnwrap(try fixture.record()).generation
        let runningBitmap = try capture(mounted)
        let runningControls = try renderedControls(in: runningBitmap, body: bodyRect(scale: 1, inline: false), scale: 1)
        XCTAssertLessThan(backgroundBrightness(in: runningBitmap, circle: runningControls.increase), 0.05)
        try await click("增加专注时长", in: mounted)
        try await fixture.flushWorker()
        XCTAssertEqual(actions.ids, ["start"], "A disabled real SwiftUI button must not dispatch a Host action.")
        XCTAssertEqual(try fixture.record()?.generation, generation)
        XCTAssertEqual(fixture.tool?.presentation.subtitle, "25 分钟 · 专注中")

        try await click("暂停", in: mounted)
        try await fixture.waitForState("已暂停")
        let remaining = try XCTUnwrap(try fixture.record()).remaining
        try await updatePlugin(mounted, fixture: fixture, scale: 1, actions: actions)
        try await settle(mounted)
        try await click("继续", in: mounted)
        try await fixture.waitForState("专注中")
        XCTAssertEqual(try fixture.record()?.remaining, remaining)
        try await updatePlugin(mounted, fixture: fixture, scale: 1, actions: actions)
        try await settle(mounted)
        try await click("结束", in: mounted)
        try await fixture.waitForState("准备专注")
        XCTAssertNil(try fixture.record())
        XCTAssertEqual(actions.ids, ["start", "pause", "resume", "stop"])

        for (label, minutes) in [("增加专注时长", 45), ("增加专注时长", 60),
                                  ("减少专注时长", 45), ("减少专注时长", 25), ("减少专注时长", 15)] {
            try await updatePlugin(mounted, fixture: fixture, scale: 1, actions: actions)
            try await settle(mounted)
            try await click(label, in: mounted)
            try await fixture.waitForState("准备专注", minutes: minutes)
            XCTAssertEqual(actions.ids.last, "preset.\(minutes)")
            XCTAssertNil(try fixture.record(), "Preset input must never start a Host countdown.")
            if minutes == 60 || minutes == 15 {
                try await updatePlugin(mounted, fixture: fixture, scale: 1, actions: actions)
                try await settle(mounted)
                let disabled = minutes == 60 ? "增加专注时长" : "减少专注时长"
                let bitmap = try capture(mounted)
                let controls = try renderedControls(in: bitmap, body: bodyRect(scale: 1, inline: false), scale: 1)
                XCTAssertLessThan(backgroundBrightness(in: bitmap, circle: controls.frame(for: disabled)), 0.05)
                let count = actions.ids.count
                try await click(disabled, in: mounted)
                try await fixture.flushWorker()
                XCTAssertEqual(actions.ids.count, count, "The endpoint button must be disabled at the native control.")
            }
        }
        fixture.assertNoFailures()
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

    private func readyFixture() async throws -> PomodoroPluginFixture {
        let fixture = try PomodoroPluginFixture()
        try await fixture.storage.set(pluginID: fixture.id, key: "settings", value: .object([
            "schemaVersion": .number(1), "selectedMinutes": .number(25), "lastSession": .string("idle")
        ]))
        try fixture.grantStorage()
        try await fixture.load()
        try await fixture.flushWorker()
        return fixture
    }

    private func mountPlugin(_ fixture: PomodoroPluginFixture, scale: CGFloat, inline: Bool = false,
                             interactive: Bool = false,
                             actions: PomodoroNativeActionCapture? = nil) throws -> PomodoroNativeMountedView {
        let capturedActions = actions ?? PomodoroNativeActionCapture()
        let clock = IslandCountdownDisplayClock()
        let size = CGSize(width: (inline ? 440 : 412) * scale, height: (inline ? 174 : 96) * scale)
        let mounted = mount(try pluginRoot(fixture, scale: scale, inline: inline, clock: clock, actions: capturedActions),
                            size: size, interactive: interactive)
        mounted.clock = clock
        return mounted
    }

    private func updatePlugin(_ mounted: PomodoroNativeMountedView, fixture: PomodoroPluginFixture,
                              scale: CGFloat, actions: PomodoroNativeActionCapture) async throws {
        XCTAssertFalse(fixture.hasUnsavedSettingsHint)
        let clock = try XCTUnwrap(mounted.clock)
        let root = try pluginRoot(fixture, scale: scale, inline: false,
                                 clock: clock, actions: actions)
        mounted.hosting.rootView = framed(root, size: mounted.exactSize)
    }

    private func pluginRoot(_ fixture: PomodoroPluginFixture, scale: CGFloat, inline: Bool,
                            clock: IslandCountdownDisplayClock, actions: PomodoroNativeActionCapture) throws -> AnyView {
        let snapshot = try XCTUnwrap(fixture.manager.toolSnapshots.first { $0.activity.source.identifier == fixture.id })
        XCTAssertTrue(fixture.manager.selectTool(snapshot))
        let renderer = IslandRenderer(presentation: snapshot.activity.presentation, mode: .expanded,
            shellSize: CGSize(width: 428 * scale, height: 146 * scale),
            countdownResolver: { fixture.lifecycle.resolveCountdown($0, for: snapshot) }, displayClock: clock) { action in
                actions.ids.append(action.actionID)
                XCTAssertEqual(fixture.router.dispatch(id: snapshot.activity.id, source: snapshot.activity.source,
                    instanceToken: snapshot.instanceToken, action: action), .handled)
            }
            .frame(width: 412 * scale, height: 96 * scale, alignment: .topLeading)
        let content: AnyView
        if inline {
            // Use the production selector and its actual budget. The empty
            // 42-point header reserves the switcher and top padding; it is
            // not a substitute screenshot of the complete production island.
            content = AnyView(VStack(spacing: IslandVisualStyle.expandedToolSelectorSpacing * scale) {
                IslandToolTabs(entries: [
                    .init(id: "stopwatch", title: "秒表", onSelect: {}),
                    .init(id: "countdown", title: "倒计时", onSelect: {}),
                    .init(id: "pomodoro", title: "番茄钟", onSelect: {})
                ], selectedID: "pomodoro")
                renderer
            }
            .padding(.top, 42 * scale).padding(.bottom, 8 * scale).padding(.horizontal, 14 * scale))
        } else {
            content = AnyView(renderer)
        }
        return AnyView(content.environment(\.islandLayoutScale, scale).environment(\.colorScheme, .dark)
            .transaction { $0.disablesAnimations = true })
    }

    private func bodyRect(scale: CGFloat, inline: Bool) -> CGRect {
        CGRect(x: inline ? 14 * scale : 0, y: inline ? 70 * scale : 0,
               width: 412 * scale, height: 96 * scale)
    }

    private func mount(_ root: AnyView, size: CGSize, interactive: Bool = false) -> PomodoroNativeMountedView {
        let canvas = CGSize(width: ceil(size.width), height: ceil(size.height))
        let hosting = NSHostingView(rootView: framed(root, size: size))
        hosting.frame = CGRect(origin: .zero, size: canvas)
        let window: NSWindow
        if interactive {
            let panel = NSPanel(contentRect: hosting.frame, styleMask: [.titled, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.hidesOnDeactivate = false
            window = panel
        } else {
            window = NSWindow(contentRect: hosting.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        }
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.isOpaque = true
        let container = NSView(frame: hosting.frame)
        window.contentView = container
        hosting.autoresizingMask = []
        container.addSubview(hosting)
        if interactive { window.center(); window.makeKeyAndOrderFront(nil) }
        return .init(hosting: hosting, window: window, exactSize: size)
    }

    private func framed(_ root: AnyView, size: CGSize) -> AnyView {
        AnyView(root.frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.black)
            .frame(width: ceil(size.width), height: ceil(size.height), alignment: .topLeading))
    }

    private func settle(_ mounted: PomodoroNativeMountedView) async throws {
        try await Task.sleep(for: .milliseconds(100))
        mounted.hosting.layoutSubtreeIfNeeded()
        mounted.hosting.displayIfNeeded()
    }

    private func renderedControls(in bitmap: NSBitmapImageRep, body: CGRect,
                                  scale: CGFloat, redPrimary: Bool = true) throws -> PomodoroNativeRenderedControls {
        let warm = circleBounds(in: bitmap, body: body, scale: scale, warm: true, redPrimary: redPrimary)
        let primary = try XCTUnwrap(warm.max { $0.width * $0.height < $1.width * $1.height },
                                   "The real filled primary circle must survive rendering.")
        let neutral = circleBounds(in: bitmap, body: body, scale: scale, warm: false)
        let stop = try XCTUnwrap(neutral.filter {
            abs($0.midY - primary.midY) < 3 * scale && $0.midX < primary.midX
        }.max { $0.midX < $1.midX }, "The real secondary reset circle must be visible.")
        let adjustments = neutral.filter { $0.midY < primary.minY + scale }.sorted { $0.midX < $1.midX }
        XCTAssertEqual(adjustments.count, 2, "Both duration adjustment circles must be painted; bounds=\(neutral)")
        return .init(decrease: try XCTUnwrap(adjustments.first), increase: try XCTUnwrap(adjustments.last),
                     stop: stop, primary: primary)
    }

    /// Connected foreground regions locate the actual circular backgrounds,
    /// including dimmed controls. Text glyphs and the thin track cannot meet
    /// the bounded circular footprint, so no authored click positions are used.
    private func circleBounds(in bitmap: NSBitmapImageRep, body: CGRect,
                              scale: CGFloat, warm: Bool, redPrimary: Bool = true) -> [CGRect] {
        let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
        var mask = [UInt8](repeating: 0, count: width * height)
        for y in max(0, Int(floor(body.minY)))..<min(height, Int(ceil(body.maxY))) {
            for x in max(0, Int(floor(body.minX)))..<min(width, Int(ceil(body.maxX))) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.1 else { continue }
                let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                let themed = redPrimary
                    ? r > 0.6 && g < 0.55 && b < 0.55 && r > g + 0.2 && r > b + 0.2
                    : r > 0.6 && g > 0.3 && g < 0.95 && b < 0.6
                let matches = warm ? themed : r > 0.015 && abs(r - g) < 0.025 && abs(g - b) < 0.025
                if matches { mask[y * width + x] = 1 }
            }
        }
        var circles: [CGRect] = []
        for start in mask.indices where mask[start] == 1 {
            mask[start] = 0
            var queue = [start], cursor = 0
            var minX = start % width, maxX = minX, minY = start / width, maxY = minY
            while cursor < queue.count {
                let index = queue[cursor], x = index % width, y = index / width
                cursor += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for next in [x > 0 ? index - 1 : -1, x + 1 < width ? index + 1 : -1,
                             y > 0 ? index - width : -1, y + 1 < height ? index + width : -1]
                where next >= 0 && mask[next] == 1 {
                    mask[next] = 0
                    queue.append(next)
                }
            }
            let rect = CGRect(x: CGFloat(minX), y: CGFloat(minY),
                              width: CGFloat(maxX - minX + 1), height: CGFloat(maxY - minY + 1))
            if rect.width >= 18 * scale, rect.height >= 18 * scale,
               rect.width / rect.height > 0.85, rect.width / rect.height < 1.15 {
                circles.append(rect)
            }
        }
        return circles
    }

    private func backgroundBrightness(in bitmap: NSBitmapImageRep, circle: CGRect) -> CGFloat {
        let x = max(0, min(bitmap.pixelsWide - 1, Int(circle.minX + circle.width * 0.22)))
        let y = max(0, min(bitmap.pixelsHigh - 1, Int(circle.minY + circle.height * 0.22)))
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
        return (color.redComponent + color.greenComponent + color.blueComponent) / 3
    }

    private func renderedText(in bitmap: NSBitmapImageRep,
                              languages: [String] = ["en-US", "zh-Hans"]) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = false
        request.customWords = ["25:00", "24:45", "设置未保存"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func timeRect(in body: CGRect) -> CGRect {
        CGRect(x: body.minX, y: body.minY, width: body.width * 0.45, height: body.height)
    }

    private func click(_ label: String, in mounted: PomodoroNativeMountedView) async throws {
        mounted.window.makeKeyAndOrderFront(nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !mounted.window.isKeyWindow {
            guard ContinuousClock.now < deadline else {
                NativeWindowTestingDiagnostics.keyTimeout(mounted.window)
                XCTFail("Pomodoro native input window did not become key.")
                throw PomodoroNativeLayoutError.windowDidNotBecomeKey
            }
            mounted.window.makeKey()
            try await Task.sleep(for: .milliseconds(10))
        }
        let bitmap = try capture(mounted)
        let controls = try renderedControls(in: bitmap, body: CGRect(origin: .zero, size: mounted.exactSize), scale: 1)
        let frame = controls.frame(for: label)
        let point = CGPoint(x: frame.midX,
                            y: mounted.hosting.isFlipped ? frame.midY : mounted.hosting.bounds.height - frame.midY)
        let location = mounted.hosting.convert(point, to: nil)
        let events = try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: mounted.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(events[1], atStart: true)
        NSApp.sendEvent(events[0])
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                    inMode: .eventTracking, dequeue: true) { NSApp.sendEvent(up) }
        try await settle(mounted)
    }

    private func capture(_ mounted: PomodoroNativeMountedView) throws -> NSBitmapImageRep {
        let size = mounted.hosting.bounds.size
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        if let bytes = bitmap.bitmapData { bytes.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh) }
        bitmap.size = size
        mounted.hosting.layoutSubtreeIfNeeded()
        mounted.hosting.displayIfNeeded()
        mounted.hosting.cacheDisplay(in: mounted.hosting.bounds, to: bitmap)
        return bitmap
    }

    private func whiteTimeBounds(in bitmap: NSBitmapImageRep, rect: CGRect) -> CGRect? {
        var result = CGRect.null
        let minX = max(0, Int(floor(rect.minX))), maxX = min(bitmap.pixelsWide, Int(ceil(rect.maxX)))
        let minY = max(0, Int(floor(rect.minY))), maxY = min(bitmap.pixelsHigh, Int(ceil(rect.maxY)))
        guard minX < maxX, minY < maxY else { return nil }
        for y in minY..<maxY {
            for x in minX..<maxX {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.8, color.redComponent > 0.82,
                      color.greenComponent > 0.82, color.blueComponent > 0.82 else { continue }
                result = result.union(CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1))
            }
        }
        return result.isNull ? nil : result
    }

    private func tomatoPixels(in bitmap: NSBitmapImageRep, rect: CGRect) -> Int {
        let minX = max(0, Int(floor(rect.minX))), maxX = min(bitmap.pixelsWide, Int(ceil(rect.maxX)))
        let minY = max(0, Int(floor(rect.minY))), maxY = min(bitmap.pixelsHigh, Int(ceil(rect.maxY)))
        return (minY..<maxY).reduce(0) { count, y in
            count + (minX..<maxX).filter { x in
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return c.alphaComponent > 0.5 && c.redComponent > 0.6 && c.greenComponent < 0.55
                    && c.blueComponent < 0.55 && c.redComponent > c.greenComponent + 0.2
                    && c.redComponent > c.blueComponent + 0.2
            }.count
        }
    }

    private func warmPixels(in bitmap: NSBitmapImageRep, rect: CGRect) -> Int {
        let minX = max(0, Int(floor(rect.minX))), maxX = min(bitmap.pixelsWide, Int(ceil(rect.maxX)))
        let minY = max(0, Int(floor(rect.minY))), maxY = min(bitmap.pixelsHigh, Int(ceil(rect.maxY)))
        guard minX < maxX, minY < maxY else { return 0 }
        return (minY..<maxY).reduce(0) { count, y in
            count + (minX..<maxX).filter { x in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return color.alphaComponent > 0.5 && color.redComponent > 0.6
                    && color.greenComponent > 0.55 && color.greenComponent < 0.95 && color.blueComponent < 0.6
            }.count
        }
    }

    private func trackRowsAtCenter(in bitmap: NSBitmapImageRep) -> Int {
        (0..<bitmap.pixelsHigh).filter { y in
            guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return color.alphaComponent > 0.1 && max(color.redComponent, color.greenComponent, color.blueComponent) > 0.07
        }.count
    }

    private func attach(_ bitmap: NSBitmapImageRep, name: String) throws {
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dynamic-island-pomodoro-native-20261030", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func scaleName(_ scale: CGFloat) -> String { String(format: "%.2f", Double(scale)) }
}

@MainActor
private final class PomodoroNativeActionCapture { var ids: [String] = [] }

private struct PomodoroNativeRenderedControls {
    let decrease: CGRect
    let increase: CGRect
    let stop: CGRect
    let primary: CGRect

    func frame(for label: String) -> CGRect {
        switch label {
        case "减少专注时长": return decrease
        case "增加专注时长": return increase
        case "结束": return stop
        default: return primary
        }
    }
}

@MainActor
private final class PomodoroNativeMountedView {
    let hosting: NSHostingView<AnyView>
    let window: NSWindow
    let exactSize: CGSize
    var clock: IslandCountdownDisplayClock?

    init(hosting: NSHostingView<AnyView>, window: NSWindow, exactSize: CGSize) {
        self.hosting = hosting
        self.window = window
        self.exactSize = exactSize
    }

    func close() {
        window.contentView = nil
        window.close()
        clock?.shutdown()
    }
}

private enum PomodoroNativeLayoutError: Error { case windowDidNotBecomeKey }
