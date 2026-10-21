import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Vision
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginExtensionsUITests: XCTestCase {
    func testCompatibilityDetailsRenderHostProfileObservationAndRecentLayoutAtReadableWidth() async throws {
        let baseline = PluginCompatibilitySnapshot.profile(for: .superIsland)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 820, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        func display(_ snapshot: PluginCompatibilitySnapshot, name: String) async throws -> String {
            let view = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
                PluginCompatibilityBadge(snapshot: snapshot)
                PluginCompatibilityDetails(snapshot: snapshot)
            }.padding(18).frame(width: 820, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = view
            // Size to the rendered content instead of giving the OCR fixture
            // a mostly empty 1400-point canvas. Order the real hosting view so
            // replacements receive SwiftUI's normal display invalidations.
            window.setContentSize(CGSize(width: 820, height: max(80, view.fittingSize.height)))
            window.orderFrontRegardless()
            try await settle(window)
            let text = try CompatibilityRenderingEvidence.renderedText(in: view)
            CompatibilityRenderingEvidence.assertEngine(snapshot.engine, pixelText: text)
            print("T37_COMPATIBILITY_\(name.uppercased())_RENDERED_TEXT=\(text)")
            try writeScreenshot(window, filename: "dynamic-island-t37-compatibility-\(name).png")
            return text
        }

        let native = try await display(.profile(for: .javaScriptCore), name: "native")
        XCTAssertTrue(native.contains("原生"))
        XCTAssertTrue(CompatibilityRenderingEvidence.containsASCIIToken("JavaScriptCore", in: native), native)
        XCTAssertFalse(native.contains("兼容详情"), "Native plugins should retain compact metadata.")
        XCTAssertFalse(native.contains("兼容范围"))

        let notRun = try await display(baseline, name: "not-run")
        for text in ["有限兼容", "当前未运行", "兼容范围", "有限视图类型", "不提供上游窗口状态", "不提供上游资源接口"] {
            XCTAssertTrue(notRun.contains(text), "Missing static Host compatibility detail: \(text)")
        }
        XCTAssertFalse(notRun.contains("此布局的显示替代"))

        let awaiting = try await display(baseline.executionDidStart(), name: "awaiting-layout")
        XCTAssertTrue(awaiting.contains("运行中"))
        XCTAssertTrue(awaiting.contains("尚无成功布局"))
        XCTAssertFalse(awaiting.contains("此布局的显示替代"))

        let plain = try await display(baseline.executionDidStart().recordingLayout([]), name: "plain-layout")
        XCTAssertTrue(plain.contains("最近成功布局"))
        XCTAssertTrue(plain.contains("此布局未使用显示替代"))
        XCTAssertTrue(plain.contains("有限兼容"), "A successful layout must not upgrade the static profile.")
        XCTAssertTrue(plain.contains("兼容范围"))

        let rendered = try await display(baseline.executionDidStart().recordingLayout(
            Set(PluginCompatibilityLayoutLimitation.allCases)), name: "details")
        for limitation in PluginCompatibilityLayoutLimitation.allCases {
            XCTAssertTrue(rendered.contains(limitation.title), "A typed layout observation was cropped: \(limitation)")
        }
        XCTAssertTrue(rendered.contains("兼容范围"))
        XCTAssertTrue(rendered.contains("有限兼容"))
    }

    func testNativeManagementWindowRendersMetadataPermissionsAndMinimumSizeToPNG() async throws {
        let fixture = try await makeFixture(permissions: PluginPermission.allCases)
        defer { fixture.cleanup() }
        let controller = PluginExtensionsWindowController(model: fixture.model)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        controller.show()
        window.setContentSize(CGSize(width: 800, height: 600))
        try await settle(window)
        XCTAssertEqual(window.title, "插件管理")
        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 800)
        XCTAssertGreaterThanOrEqual(window.contentMinSize.height, 600)
        let view = try XCTUnwrap(window.contentView)
        XCTAssertGreaterThanOrEqual(view.bounds.width, 800)
        XCTAssertGreaterThanOrEqual(view.bounds.height, 600)
        try writeScreenshot(window, filename: "dynamic-island-t33-extensions.png")
        let labels = try renderedText(in: view)
        print("T33_RENDERED_TEXT=\(labels)")
        XCTAssertEqual(fixture.model.selectedPlugin?.manifest.engine, .javaScriptCore)
        XCTAssertTrue(labels.contains("Extensions Fixture"))
        XCTAssertTrue(labels.contains("Fixture Developer"))
        XCTAssertTrue(labels.contains("未验证"))
        XCTAssertTrue(CompatibilityRenderingEvidence.containsASCIIToken("JavaScriptCore", in: labels), labels)
        for label in ["启用插件", "查看诊断", "卸载", "读取剪贴板", "写入剪贴板", "尚未支持"] {
            XCTAssertTrue(labels.contains(label), "Required control or permission was cropped: \(label)")
        }
        XCTAssertFalse(labels.contains(fixture.configuration.rootDirectoryURL.path))
    }

    func testNativeButtonsRequireExplicitConsentAndUninstallConfirmation() async throws {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session["CGSSessionScreenIsLocked"] as? Bool == true {
            throw XCTSkip("Real AppKit mouse input requires an unlocked macOS session.")
        }
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let witness = ExtensionsUIDiagnosticsWitness()
        // A nonactivating panel gives the real production View a key event
        // surface without asking macOS to activate the XCTest Host process.
        // The separate rendering tests still cover the production NSWindow.
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PluginExtensionsView(model: fixture.model,
            onShowDiagnostics: { witness.opens += 1 }))
        defer { window.close() }
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(CGSize(width: 800, height: 600))
        try await settle(window)
        let view = try XCTUnwrap(window.contentView)

        try await click(view, window: window, atTopLeftPoint: CGPoint(x: 267, y: 184))
        try await waitUntil { fixture.model.selectedPlugin?.isEnabled == true && !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.selectedSnapshot?.state, .running)
        XCTAssertTrue(fixture.model.selectedPermissionSnapshot?.states.values.allSatisfy { $0 == .requested } == true)
        XCTAssertNotNil(fixture.activities.current)

        try await click(view, window: window, atTopLeftPoint: CGPoint(x: 740, y: 287))
        let readApproval = try await sheet(of: window)
        XCTAssertTrue(nativeText(in: readApproval).contains("密码"))
        XCTAssertTrue(nativeText(in: readApproval).contains("验证码"))
        try nativeButton("取消", in: readApproval).performClick(nil)
        try await waitUntil { window.attachedSheet == nil }
        XCTAssertEqual(fixture.model.selectedPermissionSnapshot?.states[.readClipboard], .requested)
        try await click(view, window: window, atTopLeftPoint: CGPoint(x: 675, y: 287))
        try await waitUntil { fixture.model.selectedPermissionSnapshot?.states[.readClipboard] == .denied }
        try await click(view, window: window, atTopLeftPoint: CGPoint(x: 740, y: 357))
        let cancelledApproval = try await sheet(of: window)
        try nativeButton("取消", in: cancelledApproval).performClick(nil)
        try await waitUntil { window.attachedSheet == nil }
        XCTAssertEqual(fixture.model.selectedPermissionSnapshot?.states[.writeClipboard], .requested)

        try await click(view, window: window, atTopLeftPoint: CGPoint(x: 740, y: 357))
        let approval = try await sheet(of: window)
        XCTAssertTrue(nativeText(in: approval).contains("不会允许读取剪贴板"))
        try nativeButton("允许此权限", in: approval).performClick(nil)
        try await waitUntil { fixture.model.selectedPermissionSnapshot?.states[.writeClipboard] == .granted }
        XCTAssertEqual(fixture.model.selectedPermissionSnapshot?.states[.readClipboard], .denied)
        try await click(view, window: window, atTopLeftPoint: CGPoint(x: 740, y: 357))
        try await waitUntil { fixture.model.selectedPermissionSnapshot?.states[.writeClipboard] == .revoked }

        try await click(view, window: window, atTopLeftPoint: CGPoint(x: 353, y: 184))
        try await waitUntil { witness.opens == 1 }
        XCTAssertEqual(fixture.diagnosticsModel.selectedID, fixture.id)

        try await click(view, window: window, atTopLeftPoint: CGPoint(x: 267, y: 184))
        try await waitUntil { fixture.model.selectedPlugin?.isEnabled == false && !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.selectedSnapshot?.state, .disabled)
        XCTAssertNil(fixture.activities.current)
        try await settle(window)
        try writeScreenshot(window, filename: "dynamic-island-t33-management-confirmed.png")

        XCTAssertNotNil(fixture.model.managementReview(id: fixture.id))
        try await click(view, window: window, atTopLeftPoint: CGPoint(x: 751, y: 184))
        let cancelledUninstall = try await sheet(of: window)
        try nativeButton("取消", in: cancelledUninstall).performClick(nil)
        try await waitUntil { window.attachedSheet == nil }
        XCTAssertEqual(fixture.model.plugins.count, 1)
        try await click(view, window: window, atTopLeftPoint: CGPoint(x: 751, y: 184))
        let uninstall = try await sheet(of: window)
        try nativeButton("卸载插件", in: uninstall).performClick(nil)
        try await waitUntil { fixture.model.plugins.isEmpty && !fixture.model.isBusy }
        XCTAssertNil(fixture.model.selectedID)
        XCTAssertNil(fixture.lifecycle.snapshot(id: fixture.id))
    }

    func testEmptyWindowAndRejectedDiscoveryUseFixedCodesWithoutCandidatePaths() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let review = try XCTUnwrap(fixture.model.managementReview(id: fixture.id))
        await fixture.model.uninstall(review)
        fixture.model.setDiscoveryReport(.init(plugins: [], failures: [
            .init(candidateName: "SECRET-CANDIDATE", error: .candidateUnreadable("SECRET-PATH"))
        ]))
        let controller = PluginExtensionsWindowController(model: fixture.model)
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        controller.show()
        try await settle(window)
        let view = try XCTUnwrap(window.contentView)
        let labels = try renderedText(in: view)
        print("T33_REJECTED_DISCOVERY_RENDERED_TEXT=\(labels)")
        XCTAssertEqual(fixture.model.discoveryFailures.map(\.code), ["candidateUnreadable"])
        XCTAssertTrue(labels.contains("暂无已安装插件"))
        XCTAssertFalse(labels.contains("启用插件"))
        XCTAssertTrue(labels.contains("项插件未能载入"), labels)
        // Vision can confuse 是否 / 兼容 glyphs even on the local runner.
        // Require both ends of the rendered recovery instruction and the
        // exact model code rather than treating OCR as a copy spellchecker.
        XCTAssertTrue(labels.contains("请检查插件"), labels)
        XCTAssertTrue(labels.contains("重新安装"), labels)
        XCTAssertTrue(CompatibilityRenderingEvidence.containsASCIIToken("candidateUnreadable", in: labels), labels)
        XCTAssertFalse(labels.contains("SECRET-CANDIDATE"))
        XCTAssertFalse(labels.contains("SECRET-PATH"))
        XCTAssertFalse(labels.contains(fixture.configuration.rootDirectoryURL.path))
    }

    private func makeFixture(permissions: [PluginPermission] = [.readClipboard, .writeClipboard, .localStorage]) async throws -> ExtensionsUIFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PluginExtensionsUI-SECRET-PATH-\(UUID().uuidString)")
        let configuration = PluginManagerConfiguration(rootDirectoryURL: root, hostVersion: try SemanticVersion("0.6.0"))
        let activities = ActivityManager(configuration: .immediate)
        let permissionsManager = PermissionManager()
        let diagnostics = PluginDiagnosticsStore()
        let lifecycle = PluginLifecycleBridge(activityManager: activities, actionRouter: ActionRouter(manager: activities),
            permissions: permissionsManager, diagnostics: diagnostics, runtimeFactory: { _ in ExtensionsUIRuntime() })
        let manager = PluginManager(configuration: configuration, lifecycleHandler: lifecycle)
        let report = await manager.discover()
        XCTAssertTrue(report.failures.isEmpty)
        let id = "com.example.extensions.ui"
        let packageURL = configuration.installedDirectoryURL.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let manifest = try PluginManifest(id: id, name: "Extensions Fixture", version: SemanticVersion("1.0.0"),
            engine: .javaScriptCore, entry: "main.js", minimumHostVersion: SemanticVersion("0.6.0"),
            permissions: permissions, capabilities: [.publishActivity], developer: "Fixture Developer")
        try manifest.encodeJSON().write(to: packageURL.appendingPathComponent("manifest.json"))
        try Data("function onStart() {}".utf8).write(to: packageURL.appendingPathComponent("main.js"))
        _ = try await manager.load(at: packageURL)
        let diagnosticsModel = PluginDiagnosticsModel(manager: manager, lifecycle: lifecycle, diagnostics: diagnostics)
        let model = PluginExtensionsModel(manager: manager, lifecycle: lifecycle, permissions: permissionsManager,
                                          diagnostics: diagnostics, diagnosticsModel: diagnosticsModel)
        await model.refresh()
        return ExtensionsUIFixture(id: id, configuration: configuration, manager: manager, lifecycle: lifecycle,
                                   activities: activities, diagnosticsModel: diagnosticsModel, model: model)
    }

    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("A native control did not complete its Host operation.", file: file, line: line)
        throw ExtensionsUITestError.timedOut
    }

    private func renderedText(in view: NSView) throws -> String {
        try CompatibilityRenderingEvidence.renderedText(in: view)
    }

    private func click(_ view: NSView, window: NSWindow, atTopLeftPoint point: CGPoint) async throws {
        // Both AppKit controls (which synchronously track mouseUp) and
        // SwiftUI hosting controls (which receive separate down/up events)
        // run through NSApplication's native event dispatcher.
        window.makeKeyAndOrderFront(nil)
        try await settle(window)
        do { try await waitUntil { window.isKeyWindow } }
        catch {
            NativeWindowTestingDiagnostics.keyTimeout(window)
            throw error
        }
        let local = CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
        let location = view.convert(local, to: nil)
        let events = try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(events[1], atStart: true)
        NSApp.sendEvent(events[0])
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                    inMode: .eventTracking, dequeue: true) {
            NSApp.sendEvent(up)
        }
    }

    private func nativeText(in window: NSWindow) -> String {
        func visit(_ view: NSView) -> [String] {
            ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(visit)
        }
        return window.contentView.map { visit($0).joined(separator: " ") } ?? ""
    }

    private func sheet(of window: NSWindow, file: StaticString = #filePath, line: UInt = #line) async throws -> NSWindow {
        try await waitUntil(file: file, line: line) { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        // attachedSheet becomes available before the native presentation has
        // finished. Let AppKit settle before invoking a confirmation button.
        try await settle(sheet)
        return sheet
    }

    private func nativeButton(_ title: String, in window: NSWindow) throws -> NSButton {
        func visit(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(visit)
        }
        let view = try XCTUnwrap(window.contentView)
        return try XCTUnwrap(visit(view).first { $0.title == title }, "Missing native confirmation button \(title)")
    }

    private func writeScreenshot(_ window: NSWindow, filename: String) throws {
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try CompatibilityRenderingEvidence.bitmap(in: view)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 2_000)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try png.write(to: output, options: .atomic)
        print("T33_EXTENSIONS_SCREENSHOT=\(output.path)")
    }
}

@MainActor
private struct ExtensionsUIFixture {
    let id: String
    let configuration: PluginManagerConfiguration
    let manager: PluginManager
    let lifecycle: PluginLifecycleBridge
    let activities: ActivityManager
    let diagnosticsModel: PluginDiagnosticsModel
    let model: PluginExtensionsModel

    func cleanup() {
        lifecycle.shutdown()
        try? FileManager.default.removeItem(at: configuration.rootDirectoryURL)
    }
}

@MainActor
private final class ExtensionsUIRuntime: PluginLifecycleRuntime {
    func onStart(context: PluginExecutionContext) throws {
        try context.publish(IslandActivity(id: PluginJSBridge.activityID(pluginID: context.id, localID: "fixture"),
            source: context.source, priority: .normal, lifecycle: .init(policy: .persistent),
            presentation: .init(title: "Fixture Activity"), createdAt: Date()))
    }
    func onStop(reason: PluginStopReason) throws {}
    func teardown() {}
}

@MainActor
private final class ExtensionsUIDiagnosticsWitness { var opens = 0 }
private enum ExtensionsUITestError: Error { case timedOut }

/// These static rendering assertions deliberately do not share the top-one
/// OCR results used by the existing native mouse-button hit testing.
@MainActor
enum CompatibilityRenderingEvidence {
    /// Keep the actual view rendering at a fixed two pixels per point. The
    /// current screen can change between Retina and external 1x displays;
    /// small labels must not gain OCR failures solely from that change.
    static func bitmap(in view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((view.bounds.width * 2).rounded(.up)),
            pixelsHigh: Int((view.bounds.height * 2).rounded(.up)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = view.bounds.size
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    static func renderedText(in view: NSView) throws -> String {
        let bitmap = try bitmap(in: view)
        let image = try XCTUnwrap(bitmap.cgImage)
        let request = recognitionRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = request.results ?? []
        var text = observations.flatMap { $0.topCandidates(5).map(\.string) }
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        for observation in observations {
            // Chinese function words can disappear when Vision reads a dense
            // whole card. Recognize each actually detected line again using
            // the same source pixels with four pixels of surrounding context.
            let bounds = observation.boundingBox
            let pixels = CGRect(x: bounds.minX * imageBounds.width,
                                y: (1 - bounds.maxY) * imageBounds.height,
                                width: bounds.width * imageBounds.width,
                                height: bounds.height * imageBounds.height)
                .insetBy(dx: -4, dy: -4).intersection(imageBounds).integral
            guard let line = image.cropping(to: pixels) else { continue }
            let lineRequest = recognitionRequest()
            try VNImageRequestHandler(cgImage: line, options: [:]).perform([lineRequest])
            text.append(contentsOf: (lineRequest.results ?? []).flatMap { $0.topCandidates(5).map(\.string) })
            if observation.topCandidates(5).contains(where: { candidate in
                candidate.string.unicodeScalars.contains { scalar in
                    (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
                }
            }) {
                // Mixed Chinese/English language correction may normalize a
                // real camel-case engine label or mistake I for l. Recognize
                // the same detected source line with English correction off;
                // Keep only actual candidates; ASCII case/word splitting is
                // handled separately at the static OCR assertion boundary.
                let english = recognitionRequest(languages: ["en-US"], languageCorrection: false)
                try VNImageRequestHandler(cgImage: line, options: [:]).perform([english])
                text.append(contentsOf: (english.results ?? []).flatMap { $0.topCandidates(5).map(\.string) })
            }
        }
        return text.joined(separator: " ")
    }

    static func assertEngine(_ engine: PluginEngine, pixelText: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let expected = engine == .superIsland ? "SuperIsland" : "JavaScriptCore"
        let expectedLevel = PluginCompatibilitySnapshot.profile(for: engine).level.title
        XCTAssertTrue(containsASCIIToken(expected, in: pixelText),
                      "The complete engine name must be visible in rendered pixels: \(pixelText)", file: file, line: line)
        XCTAssertTrue(pixelText.contains(expectedLevel),
                      "The Host compatibility level must be visible in rendered pixels.", file: file, line: line)
    }

    /// Vision may normalize camel case or split one ASCII label into words.
    /// Match only those OCR differences; do not correct letters, append fixture
    /// labels, or apply this normalization to Manifest/model identity checks.
    static func containsASCIIToken(_ token: String, in pixelText: String) -> Bool {
        precondition(!token.isEmpty && token.utf8.allSatisfy { $0 < 128 })
        let compact = pixelText.components(separatedBy: .whitespacesAndNewlines).joined()
        return compact.range(of: token, options: .caseInsensitive,
                             locale: Locale(identifier: "en_US_POSIX")) != nil
    }

    private static func recognitionRequest(
        languages: [String] = ["zh-Hans", "en-US"],
        languageCorrection: Bool = true
    ) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = languageCorrection
        request.customWords = ["SuperIsland", "JavaScriptCore"]
        return request
    }
}

/// Emit only when a real native-input prerequisite failed. Preserve the
/// caller's original timeout assertion and do not infer a locked session from
/// failure to acquire a key window.
@MainActor
enum NativeWindowTestingDiagnostics {
    static func keyTimeout(_ window: NSWindow) {
        func describe(_ value: NSWindow?) -> [String: Any] {
            guard let value else { return [:] }
            return [
                "number": value.windowNumber,
                "class": String(describing: type(of: value)),
                "canBecomeKey": value.canBecomeKey,
                "isKey": value.isKeyWindow,
                "isMain": value.isMainWindow,
                "isVisible": value.isVisible,
                "isMiniaturized": value.isMiniaturized,
                "isOnActiveSpace": value.isOnActiveSpace,
                "backingScale": value.backingScaleFactor,
                "screenScale": value.screen?.backingScaleFactor ?? -1,
                "styleMask": value.styleMask.rawValue,
                "collectionBehavior": value.collectionBehavior.rawValue,
                "occlusionState": value.occlusionState.rawValue,
                "attachedSheetNumber": value.attachedSheet?.windowNumber ?? -1
            ]
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        var reportedSession: [String: Any] = [:]
        for key in ["CGSSessionScreenIsLocked", kCGSessionOnConsoleKey as String, kCGSessionLoginDoneKey as String] {
            reportedSession[key] = session?[key] ?? "not reported"
        }
        let record: [String: Any] = [
            "dateUTC": ISO8601DateFormatter().string(from: Date()),
            "target": describe(window),
            "appKeyWindow": describe(NSApp.keyWindow),
            "appMainWindow": describe(NSApp.mainWindow),
            "appModalWindow": describe(NSApp.modalWindow),
            "appActive": NSApp.isActive,
            "appHidden": NSApp.isHidden,
            "appActivationPolicy": NSApp.activationPolicy().rawValue,
            "frontmostBundleID": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "not reported",
            "currentEventType": NSApp.currentEvent.map { Int($0.type.rawValue) } ?? -1,
            "session": reportedSession
        ]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print("NATIVE_KEY_WINDOW_TIMEOUT=\(text)")
        }
    }
}
