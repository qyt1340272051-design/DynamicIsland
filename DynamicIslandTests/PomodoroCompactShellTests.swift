import AppKit
import Combine
import SwiftUI
import XCTest
@testable import DynamicIsland

/// Runs the official Pomodoro under an isolated identity through the VM, broker,
/// renderer and shell. These are controlled pixel probes, not device acceptance.
@MainActor
final class PomodoroCompactShellTests: XCTestCase {
    func testShellRightEdgeTracksActualCountdownGlyphsAtEveryFormatAndScale() async throws {
        let fixture = try CompactShellFixture()
        defer { fixture.close() }
        try await fixture.load()
        let suite = "PomodoroCompactShellTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(IslandAppearance.classic.rawValue, forKey: IslandAppearance.defaultsKey)
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("di-u12-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        print("COMPACT_SHELL_EVIDENCE=\(evidence.path)")

        for scale: CGFloat in [0.875, 1, 1.75] {
            fixture.model.setScreenEnvironment(screen(scale: scale))
            XCTAssertEqual(fixture.model.displayLayout.scale, scale, accuracy: 0.001)
            let size = fixture.model.displayLayout.panelSize
            let hosting = NSHostingView(rootView: IslandView(viewModel: fixture.model, activityRuntime: fixture.runtime)
                .defaultAppStorage(defaults)
                .environment(\.colorScheme, .dark)
                // Pixel assertions read a 1x bitmap, so match it on any display scale.
                .environment(\.displayScale, 1)
                .transaction { $0.disablesAnimations = true }
                .background(Color(red: 0.18, green: 0.22, blue: 0.24)))
            hosting.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.contentView = hosting
            defer { window.close() }
            var shellWidths: [String: CGFloat] = [:]
            var shellOrigins: [CGFloat] = []

            for (action, expected) in [("short", "15:00"), ("focus", "25:00"), ("hour", "1:00:00")] {
                try await fixture.freeze(action: action, expected: expected)
                try await Task.sleep(for: .milliseconds(400))
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try capture(hosting, size: size)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let name = "compact-shell-\(action)-scale-\(scale)"
                try png.write(to: evidence.appendingPathComponent(name + ".png"))
                let swiftUIReference = try captureSwiftUIComposite(hosting, size: size)
                try XCTUnwrap(swiftUIReference.representation(using: .png, properties: [:]))
                    .write(to: evidence.appendingPathComponent(name + "-swiftui-color-reference.png"))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)

                let shell = try XCTUnwrap(bounds(in: bitmap) { self.isShell($0) })
                let cameraLeft = (size.width - fixture.model.displayLayout.compactSize.width) / 2
                let cameraRight = (size.width + fixture.model.displayLayout.compactSize.width) / 2
                let compact = try XCTUnwrap(fixture.runtime.manager.current?.presentation.compact)
                guard case .hStack(let compactRow) = compact else {
                    return XCTFail("The official compact timer must retain its two-wing row")
                }
                XCTAssertEqual(compactRow.children.first, .icon(.init("timer", color: .danger)),
                    "The exact current compact tree must retain the requested tomato-red icon")
                let digits = try XCTUnwrap(bounds(in: bitmap, afterX: cameraRight) { self.isTomato($0) })
                // cacheDisplay retains the actual mounted geometry but loses SF
                // symbol tint beneath the island's mask on this macOS release.
                // Locate that exact glyph, then verify its color using SwiftUI's
                // compositor in the same bounded region. Hidden platform-view
                // placeholders elsewhere in ImageRenderer cannot enter this ROI.
                let icon = try XCTUnwrap(bounds(in: bitmap, beforeX: cameraLeft) {
                    self.isTomato($0) || ($0.alphaComponent > 0.5
                        && min($0.redComponent, $0.greenComponent, $0.blueComponent) > 0.5)
                })
                let redIcon = try XCTUnwrap(bounds(in: swiftUIReference,
                    rect: icon.insetBy(dx: -scale, dy: -scale), matching: isTomato),
                    "SwiftUI must paint the exact mounted timer glyph red; see \(name)-swiftui-color-reference.png")
                XCTAssertEqual(redIcon.width, icon.width, accuracy: 2,
                    "The red color reference must preserve the complete mounted timer symbol")
                XCTAssertEqual(redIcon.height, icon.height, accuracy: 2)
                XCTAssertGreaterThan(redIcon.width / scale, 9)
                let iconROI = icon.insetBy(dx: -scale, dy: -scale).integral
                let shape = iconMask(in: bitmap, rect: iconROI) {
                    self.isTomato($0) || ($0.alphaComponent > 0.5
                        && min($0.redComponent, $0.greenComponent, $0.blueComponent) > 0.5)
                }
                let redShape = iconMask(in: swiftUIReference, rect: iconROI, matching: isTomato)
                var bestOverlap = 0.0
                for dx in -1...1 {
                    for dy in -1...1 {
                        let registered = Set(redShape.map { $0 + dy * bitmap.pixelsWide + dx })
                        let union = shape.union(registered).count
                        if union > 0 {
                            bestOverlap = max(bestOverlap, Double(shape.intersection(registered).count) / Double(union))
                        }
                    }
                }
                XCTAssertGreaterThanOrEqual(bestOverlap, 0.6,
                    "The red reference must match the mounted timer's actual mask within one pixel; overlap=\(bestOverlap)")
                XCTAssertLessThanOrEqual(Double(redShape.count), Double(shape.count) * 1.2 + 2,
                    "A broad red placeholder must not substitute for the timer glyph")
                try saveCrop(swiftUIReference, rect: iconROI,
                    to: evidence.appendingPathComponent(name + "-swiftui-timer-icon.png"))
                try saveCrop(bitmap, rect: iconROI,
                    to: evidence.appendingPathComponent(name + "-appkit-timer-icon.png"))
                print("COMPACT_ICON_COLOR_MASK \(name) mounted=\(shape.count) red=\(redShape.count) registeredIoU=\(bestOverlap)")
                let outerGap = (shell.maxX - digits.maxX) / scale
                let cameraGap = (digits.minX - cameraRight) / scale
                XCTAssertGreaterThanOrEqual(outerGap, 4, name)
                XCTAssertLessThanOrEqual(outerGap, 12,
                    "\(name): shell must hug the actual digits, not the 58 pt long-format reserve; outer gap=\(outerGap)")
                XCTAssertGreaterThanOrEqual(cameraGap, 2, name)
                XCTAssertLessThanOrEqual(cameraGap, 9, "\(name): allows native glyph side bearings and pixel rounding")
                XCTAssertGreaterThan(icon.width / scale, 9, "The real left timer glyph must remain visible")
                XCTAssertLessThanOrEqual((cameraLeft - icon.maxX) / scale, 10,
                    "The shell must preserve the camera's fixed left edge")
                shellWidths[action] = shell.width / scale
                shellOrigins.append(shell.minX / scale)
                let diagnostic = "\(name): shell=\(shell), digits=\(digits), icon=\(icon), camera=\(cameraLeft)...\(cameraRight), outerGap=\(outerGap), cameraGap=\(cameraGap)"
                try diagnostic.write(to: evidence.appendingPathComponent(name + "-bounds.txt"), atomically: true, encoding: .utf8)
                print(diagnostic)
                let text = XCTAttachment(string: diagnostic)
                text.name = name + "-bounds"
                text.lifetime = .keepAlways
                add(text)
            }
            XCTAssertGreaterThan(try XCTUnwrap(shellWidths["hour"]), try XCTUnwrap(shellWidths["focus"]) + 6,
                "The physical right shell edge must grow only when the time format grows")
            XCTAssertLessThanOrEqual(try XCTUnwrap(shellOrigins.max()) - XCTUnwrap(shellOrigins.min()), 1.5,
                "Changing the right wing must not move the camera or left wing")
        }
    }

    func testRunningHourTransitionShrinksMountedShellWithoutRebuildingOnOrdinaryTicks() async throws {
        let fixture = try CompactShellFixture()
        defer { fixture.close() }
        try await fixture.load()
        fixture.model.setScreenEnvironment(screen(scale: 1))
        let suite = "PomodoroWidthTransition.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(IslandAppearance.classic.rawValue, forKey: IslandAppearance.defaultsKey)
        let size = fixture.model.displayLayout.panelSize
        let hosting = NSHostingView(rootView: IslandView(viewModel: fixture.model, activityRuntime: fixture.runtime)
            .defaultAppStorage(defaults).environment(\.colorScheme, .dark)
            .transaction { $0.disablesAnimations = true }
            .background(Color(red: 0.18, green: 0.22, blue: 0.24)))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        try await fixture.freeze(action: "hour", expected: "1:00:00")
        try await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()
        let before = try XCTUnwrap(bounds(in: capture(hosting, size: size)) { self.isShell($0) })
        try await fixture.resume()
        await Task.yield()
        var widthChanges = 0
        let observation = fixture.runtime.compactCountdownLayout.$widths.dropFirst().sink { _ in widthChanges += 1 }
        defer { observation.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while fixture.runtime.compactCountdownLayout.widths != [IslandCompactLayout.countdownTextWidth("59:59")] {
            guard ContinuousClock.now < deadline else {
                XCTFail("The visible running leaf must resize the mounted shell on its own display pulse")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()
        let image = try capture(hosting, size: size)
        let after = try XCTUnwrap(bounds(in: image) { self.isShell($0) })
        XCTAssertLessThan(after.width, before.width - 6)
        XCTAssertEqual(after.minX, before.minX, accuracy: 1)
        XCTAssertEqual(widthChanges, 1, "The hour-to-minute transition publishes exactly one new width")
        let settledChanges = widthChanges
        try await Task.sleep(for: .milliseconds(2100))
        XCTAssertEqual(widthChanges, settledChanges, "Ordinary seconds must not invalidate the parent island")
    }

    private func isShell(_ color: NSColor) -> Bool {
        color.alphaComponent > 0.9 && max(color.redComponent, color.greenComponent, color.blueComponent) < 0.05
    }

    private func screen(scale: CGFloat) -> ScreenEnvironment {
        let width: CGFloat = 1600
        let height: CGFloat = 1000
        let notchHeight = 32 * scale
        let gap = 179 * scale
        let side = (width - gap) / 2
        return ScreenEnvironment(displayID: 12, name: "Compact shell pixel probe",
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            visibleFrame: CGRect(x: 0, y: 0, width: width, height: height - notchHeight),
            safeAreaInsets: .init(top: notchHeight),
            auxiliaryTopLeftArea: CGRect(x: 0, y: height - notchHeight, width: side, height: notchHeight),
            auxiliaryTopRightArea: CGRect(x: side + gap, y: height - notchHeight, width: side, height: notchHeight),
            backingScaleFactor: 1, isBuiltIn: true)
    }

    /// Independent symbol-color reference only: ImageRenderer cannot flatten
    /// the hidden AppKit-backed controls elsewhere in the full IslandView.
    private func captureSwiftUIComposite<Content: View>(_ view: NSHostingView<Content>, size: CGSize) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.rootView.frame(width: size.width, height: size.height))
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.scale = 1
        renderer.isOpaque = false
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        bitmap.size = size
        return bitmap
    }

    /// Captures the existing mounted graph, including clock-driven shell size.
    private func capture<Content: View>(_ view: NSHostingView<Content>, size: CGSize) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width)), pixelsHigh: Int(ceil(size.height)), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        view.displayIfNeeded()
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func isTomato(_ color: NSColor) -> Bool {
        color.alphaComponent > 0.5 && color.redComponent > 0.6
            && color.greenComponent < 0.55 && color.blueComponent < 0.55
            && color.redComponent > color.greenComponent + 0.2
            && color.redComponent > color.blueComponent + 0.2
    }

    private func iconMask(in bitmap: NSBitmapImageRep, rect: CGRect,
                          matching predicate: (NSColor) -> Bool) -> Set<Int> {
        var result = Set<Int>()
        for x in max(0, Int(rect.minX))..<min(bitmap.pixelsWide, Int(rect.maxX)) {
            for y in max(0, Int(rect.minY))..<min(bitmap.pixelsHigh, Int(rect.maxY)) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), predicate(color) else { continue }
                result.insert(y * bitmap.pixelsWide + x)
            }
        }
        return result
    }

    private func saveCrop(_ bitmap: NSBitmapImageRep, rect: CGRect, to url: URL) throws {
        let bounds = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        let crop = try XCTUnwrap(bitmap.cgImage?.cropping(to: rect.intersection(bounds).integral))
        try XCTUnwrap(NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]))
            .write(to: url)
    }

    private func bounds(in bitmap: NSBitmapImageRep, rect: CGRect,
                        matching predicate: (NSColor) -> Bool) -> CGRect? {
        var result = CGRect.null
        for x in max(0, Int(floor(rect.minX)))..<min(bitmap.pixelsWide, Int(ceil(rect.maxX))) {
            for y in max(0, Int(floor(rect.minY)))..<min(bitmap.pixelsHigh, Int(ceil(rect.maxY))) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), predicate(color) else { continue }
                result = result.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return result.isNull ? nil : result
    }

    private func bounds(in bitmap: NSBitmapImageRep, afterX: CGFloat = 0,
                        beforeX: CGFloat = .greatestFiniteMagnitude,
                        matching predicate: (NSColor) -> Bool) -> CGRect? {
        var rect = CGRect.null
        for x in max(0, Int(afterX))..<min(bitmap.pixelsWide, Int(min(beforeX, CGFloat(bitmap.pixelsWide)))) {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), predicate(color) else { continue }
                rect = rect.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return rect.isNull ? nil : rect
    }
}

@MainActor
private final class CompactShellFixture {
    let id = "com.example.compact-shell"
    let model = IslandViewModel.preview()
    let root: URL
    let package: ValidatedPluginPackage
    let runtime: IslandActivityRuntime

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("compact-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/plugin-system/examples/pomodoro")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("manifest.json"))) as? [String: Any])
        manifest["id"] = id
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
        try Data(contentsOf: source.appendingPathComponent("index.js")).write(to: root.appendingPathComponent("index.js"))
        package = try PluginValidator().validateExpandedPackage(at: root,
            context: .init(hostVersion: SemanticVersion("0.6.1"), occupiedPluginIDs: [], allowedContainerURL: root.deletingLastPathComponent()))
        runtime = IslandActivityRuntime(viewModel: model)
    }

    func load() async throws {
        runtime.pluginLifecycle.pluginDidLoad(package, isEnabled: true)
        try await wait { self.runtime.manager.toolSnapshots.contains { $0.activity.source.identifier == self.id } }

    }

    func freeze(action: String, expected: String) async throws {
        model.setHovering(true)
        if runtime.manager.current?.presentation.subtitle?.hasSuffix("准备专注") != true {
            try await act("stop")
            try await wait("stopped") { self.runtime.manager.current?.presentation.subtitle?.hasSuffix("准备专注") == true }
        }
        let preset = action == "short" ? 15 : action == "hour" ? 60 : 25
        let presets = [15, 25, 45, 60]
        while runtime.manager.current?.presentation.subtitle != "\(preset) 分钟 · 准备专注" {
            let current = Int(runtime.manager.current?.presentation.subtitle?.split(separator: " ").first ?? "") ?? 25
            let index = try XCTUnwrap(presets.firstIndex(of: current))
            let next = presets[index + (current < preset ? 1 : -1)]
            // Use the actual adjacent +/- controls the official layout exposes.
            try await retry("preset.\(next)", label: "preset \(next)") {
                self.runtime.manager.current?.presentation.subtitle == "\(next) 分钟 · 准备专注"
            }
        }
        try await act("start")
        try await wait("started \(preset)") { self.runtime.manager.current?.presentation.subtitle == "\(preset) 分钟 · 专注中" }
        try await act("pause")
        try await wait("paused \(expected)") {
            guard let snapshot = self.runtime.manager.currentSnapshot,
                  snapshot.activity.presentation.subtitle == "\(preset) 分钟 · 已暂停",
                  let reference = snapshot.activity.presentation.compact?.countdownReferences.first else { return false }
            return self.runtime.resolveCountdown(reference, for: snapshot)?.text == expected
        }
        model.endHovering()
        try await wait { self.runtime.manager.currentSnapshot?.activity.source.identifier == self.id }
    }

    func resume() async throws {
        model.setHovering(true)
        try await act("resume")
        try await wait { self.runtime.manager.current?.presentation.subtitle == "60 分钟 · 专注中" }
        model.endHovering()
    }

    private func act(_ actionID: String) async throws {
        let tool = try XCTUnwrap(runtime.manager.toolSnapshots.first { $0.activity.source.identifier == id })
        XCTAssertTrue(runtime.selectTool(tool))
        XCTAssertEqual(runtime.router.dispatch(id: tool.activity.id, source: tool.activity.source,
            instanceToken: tool.instanceToken, action: .init(actionID: actionID, value: .none)), .handled)
        // The official plugin ignores overlapping user actions while its
        // previous command is in flight; allow the VM acknowledgement to settle.
        try await Task.sleep(for: .milliseconds(50))
    }

    /// The plugin can drop a preset action while a startup command is in
    /// flight, so repeat this idempotent action until its state appears.
    private func retry(_ actionID: String, label: String, until condition: @MainActor () -> Bool) async throws {
        for _ in 0..<8 {
            try await act(actionID)
            for _ in 0..<50 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
            if condition() { return }
        }
        try await wait(label, condition)
    }

    private func wait(_ label: String = "ready", _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("The real compact shell plugin did not settle at \(label). current=\(String(describing: runtime.manager.current?.presentation.subtitle)), lifecycle=\(String(describing: runtime.pluginLifecycle.snapshot(id: id))), diagnostics=\(runtime.pluginDiagnostics.records(for: id))")
                throw FixtureError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func close() {
        runtime.shutdownPlugins()
        try? FileManager.default.removeItem(at: root)
    }

    private enum FixtureError: Error { case timeout }
}
