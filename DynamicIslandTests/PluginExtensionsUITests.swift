import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Vision
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginExtensionsUITests: XCTestCase {
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
        XCTAssertTrue(labels.contains("Extensions Fixture"))
        XCTAssertTrue(labels.contains("Fixture Developer"))
        XCTAssertTrue(labels.contains("未验证"))
        XCTAssertTrue(labels.contains("JavaScriptCore"))
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
        XCTAssertTrue(labels.contains("暂无已安装插件"))
        XCTAssertFalse(labels.contains("启用插件"))
        XCTAssertTrue(labels.contains("candidateUnreadable"))
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
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func click(_ view: NSView, window: NSWindow, atTopLeftPoint point: CGPoint) async throws {
        // Both AppKit controls (which synchronously track mouseUp) and
        // SwiftUI hosting controls (which receive separate down/up events)
        // run through NSApplication's native event dispatcher.
        window.makeKeyAndOrderFront(nil)
        try await settle(window)
        try await waitUntil { window.isKeyWindow }
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
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
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
