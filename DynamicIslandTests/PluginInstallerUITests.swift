import AppKit
import CoreGraphics
import Foundation
import Vision
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginInstallerUITests: XCTestCase {
    func testSuperIslandPreviewShowsStaticLimitationsAndNotRunWithoutExecutingPackage() async throws {
        let fixture = try await InstallerUIFixture.make()
        defer { fixture.cleanup() }
        let model = PluginInstallerModel(installer: fixture.installer)
        let imported = await model.importArchive(try fixture.archive(version: "1.0.0", permissions: [], engine: .superIsland))
        XCTAssertTrue(imported)
        XCTAssertEqual(model.review?.engine, .superIsland)
        let controller = PluginInstallerWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        defer { controller.finishClose() }
        controller.show()
        window.setContentSize(CGSize(width: 640, height: 520))
        try await settle(window)
        let view = try XCTUnwrap(window.contentView)
        let compact = try CompatibilityRenderingEvidence.renderedText(in: view)
        CompatibilityRenderingEvidence.assertEngine(.superIsland, pixelText: compact)
        print("T37_SUPERISLAND_PREVIEW_MINIMUM_RENDERED_TEXT=\(compact)")
        for required in ["有限兼容", "当前未运行", "安装不会授予权限"] {
            XCTAssertTrue(compact.contains(required), "A compatibility preview label was cropped: \(required)")
        }
        XCTAssertFalse(compact.contains("最近成功布局"))
        try writeScreenshot(window, filename: "dynamic-island-t37-superisland-preview-minimum.png")

        // The production view remains scrollable at its minimum size. Render
        // a taller review as well to verify every static detail's actual text.
        window.setContentSize(CGSize(width: 820, height: 1200))
        try await settle(window)
        let expanded = try CompatibilityRenderingEvidence.renderedText(in: view)
        CompatibilityRenderingEvidence.assertEngine(.superIsland, pixelText: expanded)
        print("T37_SUPERISLAND_PREVIEW_DETAILS_RENDERED_TEXT=\(expanded)")
        for limitation in PluginCompatibilityProfileLimitation.allCases {
            XCTAssertTrue(expanded.contains(limitation.title), "Missing reviewed engine limitation: \(limitation)")
        }
        XCTAssertFalse(expanded.contains("此布局的显示替代"))
        XCTAssertFalse(expanded.contains(fixture.configuration.rootDirectoryURL.path))
        XCTAssertEqual(fixture.starts.value, 0, "Reviewing compatibility must not execute staged code.")
        XCTAssertNil(fixture.lifecycle.snapshot(id: fixture.id))
        try writeScreenshot(window, filename: "dynamic-island-t37-superisland-preview-details.png")
        _ = await model.cancel()
    }

    func testNativePreviewRendersMetadataPrivacyAndDisabledInstallPolicyAtMinimumSize() async throws {
        let fixture = try await InstallerUIFixture.make()
        defer { fixture.cleanup() }
        let model = PluginInstallerModel(installer: fixture.installer)
        _ = await model.importArchive(try fixture.archive(version: "1.0.0", permissions: [.readClipboard]))
        let controller = PluginInstallerWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        defer { controller.finishClose() }
        controller.show()
        window.setContentSize(CGSize(width: 640, height: 520))
        try await settle(window)
        XCTAssertEqual(window.title, "安装插件")
        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 640)
        XCTAssertGreaterThanOrEqual(window.contentMinSize.height, 520)
        let text = try renderedText(window).map(\.text).joined(separator: " ")
        print("T34_INSTALLER_RENDERED_TEXT=\(text)")
        for required in ["Installer Fixture", "Fixture Developer", "未验证", "读取剪贴板", "密码", "取消", "安装插件", "不会授予权限"] {
            XCTAssertTrue(text.contains(required), "A required review label was cropped: \(required)")
        }
        XCTAssertFalse(text.contains(fixture.configuration.rootDirectoryURL.path))
        XCTAssertFalse(text.contains("SECRET-SOURCE"))
        try writeScreenshot(window, filename: "dynamic-island-t34-install-preview.png")
        _ = await model.cancel()
    }

    func testNativeCancelWindowCloseAndInstallButtonsUseTheCurrentReview() async throws {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session["CGSSessionScreenIsLocked"] as? Bool == true {
            throw XCTSkip("Real AppKit mouse input requires an unlocked macOS session.")
        }
        let fixture = try await InstallerUIFixture.make()
        defer { fixture.cleanup() }
        let model = PluginInstallerModel(installer: fixture.installer)
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false
        let controller = PluginInstallerWindowController(model: model, eventWindow: panel)
        let window = try XCTUnwrap(controller.window)
        defer { controller.finishClose() }
        window.setContentSize(CGSize(width: 640, height: 520))
        let archive = try fixture.archive(version: "1.0.0", permissions: [.readClipboard, .writeClipboard])
        _ = await model.importArchive(archive)
        controller.show()
        try await click("取消", in: window)
        try await InstallerUIFixture.wait { model.review == nil && !window.isVisible }
        XCTAssertEqual(try fixture.stagedCount(), 0)
        let firstListed = await fixture.manager.plugins()
        XCTAssertTrue(firstListed.isEmpty)

        _ = await model.importArchive(archive)
        controller.show()
        try await settle(window)
        window.performClose(nil)
        try await InstallerUIFixture.wait { model.review == nil && !window.isVisible }
        XCTAssertEqual(try fixture.stagedCount(), 0)

        _ = await model.importArchive(archive)
        controller.show()
        try await click("安装插件", in: window)
        try await InstallerUIFixture.wait { model.installedID == fixture.id && !model.isBusy }
        XCTAssertNil(model.review)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(fixture.starts.value, 0)
        let listed = await fixture.manager.plugins()
        let plugin = try XCTUnwrap(listed.first)
        XCTAssertFalse(plugin.isEnabled)
        let validated = await fixture.manager.validatedPackage(id: fixture.id)
        let package = try XCTUnwrap(validated)
        let states = try fixture.permissions.snapshot(package: package).states
        XCTAssertEqual(states[.readClipboard], .requested)
        XCTAssertEqual(states[.writeClipboard], .requested)
        XCTAssertEqual(try fixture.stagedCount(), 0)
        try await settle(window)
        try writeScreenshot(window, filename: "dynamic-island-t34-installed-disabled.png")
    }

    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
    }

    private func click(_ label: String, in window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        try await settle(window)
        try await InstallerUIFixture.wait { window.isKeyWindow }
        let matches = try renderedText(window).filter { $0.text.contains(label) }
        let text = try XCTUnwrap(matches.min { $0.bounds.minY < $1.bounds.minY }, "Missing rendered native button \(label)")
        let view = try XCTUnwrap(window.contentView)
        // Vision rectangles use a lower-left origin. Pick the lowest matching
        // label so the title never gets mistaken for the footer Install button.
        let point = CGPoint(x: text.bounds.midX * view.bounds.width,
                            y: view.isFlipped ? (1 - text.bounds.midY) * view.bounds.height : text.bounds.midY * view.bounds.height)
        let location = view.convert(point, to: nil)
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

    private func renderedText(_ window: NSWindow) throws -> [(text: String, bounds: CGRect)] {
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.customWords = ["SuperIsland", "JavaScriptCore"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return (text, observation.boundingBox)
        }
    }

    private func writeScreenshot(_ window: NSWindow, filename: String) throws {
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try png.write(to: output, options: .atomic)
        print("T34_INSTALLER_SCREENSHOT=\(output.path)")
    }
}
