import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Vision
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginRegistryUITests: XCTestCase {
    func testMinimumWindowRendersInitialEmptyFailureAndCompatibilityStates() async throws {
        let f = try await RegistryUIFixture.make()
        defer { f.base.cleanup() }
        let future = try RegistryUIFixture.entry(bytes: f.bytes, minimum: "9.0.0", id: "com.example.future", name: "未来版本插件")
        let catalog = try RegistryUIFixture.catalog([f.entry, future])
        let cases: [(String, Result<PluginRegistryCatalog, Error>?, [String])] = [
            ("initial", nil, ["发现插件", "刷新目录", "不会自动联网"]),
            ("empty", .success(try RegistryUIFixture.catalog([])), ["暂时没有可用插件", "已获取目录"]),
            ("unavailable", .failure(PluginRegistryError.httpStatus), ["暂不可用", "尚未发布", "httpStatus"]),
            ("entries", .success(catalog), ["Installer Fixture", "未来版本插件", "下载并查看", "需要更新"])
        ]
        for (name, outcome, expected) in cases {
            let model = f.discovery(loader: { _ in try (outcome ?? .success(catalog)).get() })
            if outcome != nil { await model.refresh() }
            let controller = PluginRegistryWindowController(model: model, onDownload: { _ in XCTFail("Rendering started download") })
            let window = try XCTUnwrap(controller.window)
            controller.show()
            window.setContentSize(CGSize(width: 720, height: 480))
            try await settle(window)
            let text = try CompatibilityRenderingEvidence.renderedText(in: XCTUnwrap(window.contentView))
            for label in expected { XCTAssertTrue(text.contains(label), "Missing \(label) in \(name): \(text)") }
            XCTAssertTrue(text.contains("安装不会自动启用或授权"))
            XCTAssertFalse(text.contains(f.base.configuration.rootDirectoryURL.path))
            try screenshot(window, name: "registry-\(name)")
            controller.close()
        }
        XCTAssertEqual(try f.base.stagedCount(), 0)
        XCTAssertEqual(f.base.starts.value, 0)
    }

    func testDiscoveryToolbarFitsExistingMinimumManagementWindow() async throws {
        let f = try await RegistryUIFixture.make()
        defer { f.base.cleanup() }
        let model = PluginExtensionsModel(manager: f.base.manager, lifecycle: f.base.lifecycle,
            permissions: f.base.permissions, diagnostics: PluginDiagnosticsStore())
        let controller = PluginExtensionsWindowController(model: model, onImport: {}, onDiscover: {})
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        controller.show()
        window.setContentSize(CGSize(width: 800, height: 600))
        try await settle(window)
        let text = try CompatibilityRenderingEvidence.renderedText(in: XCTUnwrap(window.contentView))
        for label in ["插件管理", "导入插件", "发现", "刷新"] { XCTAssertTrue(text.contains(label)) }
        try screenshot(window, name: "registry-management-entry")
    }

    func testClosingDiscoveryCancelsRefreshAndDropsLateCatalog() async throws {
        let f = try await RegistryUIFixture.make()
        defer { f.base.cleanup() }
        let gate = RegistryAsyncGate()
        let model = f.discovery(loader: { _ in await gate.wait(); return f.catalog })
        let controller = PluginRegistryWindowController(model: model, onDownload: { _ in })
        let window = try XCTUnwrap(controller.window)
        controller.show()
        let loading = Task { await model.refresh() }
        try await InstallerUIFixture.wait { model.phase == .loading }
        try await settle(window)
        let text = try CompatibilityRenderingEvidence.renderedText(in: XCTUnwrap(window.contentView))
        XCTAssertTrue(text.contains("正在读取插件目录"))
        XCTAssertTrue(text.contains("取消刷新"))
        try screenshot(window, name: "registry-loading")
        window.performClose(nil)
        XCTAssertEqual(model.phase, .cancelling)
        await gate.release()
        await loading.value
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(window.isVisible)
    }

    func testClosingInstallerCancelsActualPendingDownloadAndAllowsRetry() async throws {
        let f = try await RegistryUIFixture.make()
        defer { f.base.cleanup() }
        RegistryDiscoveryProtocol.configure(catalog: Data(), archive: f.bytes, holdArchive: true)
        let client = PluginRegistryClient(protocolClasses: [RegistryDiscoveryProtocol.self])
        let installer = PluginInstallerModel(installer: f.base.installer, registryPrepare: { entry in
            try await client.prepareDownload(entry, installer: f.base.installer)
        })
        let controller = PluginInstallerWindowController(model: installer)
        let window = try XCTUnwrap(controller.window)
        defer { controller.finishClose() }
        controller.show()
        let downloading = Task { await installer.importRegistryEntry(f.entry) }
        try await InstallerUIFixture.wait { installer.canCancelDownload && RegistryDiscoveryProtocol.requests.count == 1 }
        try await settle(window)
        let text = try CompatibilityRenderingEvidence.renderedText(in: XCTUnwrap(window.contentView))
        XCTAssertTrue(text.contains("正在下载并校验"))
        XCTAssertTrue(text.contains("取消下载"))
        try screenshot(window, name: "registry-downloading")
        window.performClose(nil)
        let imported = await downloading.value
        XCTAssertFalse(imported)
        try await InstallerUIFixture.wait { !window.isVisible }
        XCTAssertFalse(installer.hasPendingImport)
        XCTAssertEqual(try f.base.stagedCount(), 0)
        RegistryDiscoveryProtocol.configure(catalog: Data(), archive: f.bytes)
        let retried = await installer.importRegistryEntry(f.entry)
        XCTAssertTrue(retried)
        _ = await installer.cancel()
    }

    func testNativeRefreshDownloadAndInstallPreserveExplicitConsent() async throws {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], session["CGSSessionScreenIsLocked"] as? Bool == true {
            throw XCTSkip("Real AppKit mouse input requires an unlocked macOS session.")
        }
        let f = try await RegistryUIFixture.make()
        defer { f.base.cleanup() }
        let catalogData = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "plugins": [[
            "id": f.entry.id, "name": f.entry.name, "version": f.entry.version.description,
            "minHostVersion": f.entry.minHostVersion.description, "source": f.entry.source.absoluteString,
            "download": f.entry.download.absoluteString, "hash": f.entry.hash
        ]]])
        RegistryDiscoveryProtocol.configure(catalog: catalogData, archive: f.bytes)
        let client = PluginRegistryClient(protocolClasses: [RegistryDiscoveryProtocol.self])
        let installer = PluginInstallerModel(installer: f.base.installer, registryPrepare: { entry in
            try await client.prepareDownload(entry, installer: f.base.installer)
        })
        let model = PluginRegistryModel(hostVersion: f.base.configuration.hostVersion, installerModel: installer,
            loadCatalog: { try await client.loadCatalog(from: $0) })
        let installController = PluginInstallerWindowController(model: installer, eventWindow: panel(width: 640, height: 520))
        let controller = PluginRegistryWindowController(model: model, eventWindow: panel(width: 720, height: 480), onDownload: { entry in
            Task { installController.show(); _ = await model.download(entry) }
        })
        defer { controller.close(); installController.finishClose() }
        let window = try XCTUnwrap(controller.window), preview = try XCTUnwrap(installController.window)
        controller.show()
        XCTAssertTrue(RegistryDiscoveryProtocol.requests.isEmpty)
        try await click("刷新目录", in: window)
        try await InstallerUIFixture.wait { model.entries.count == 1 }
        XCTAssertEqual(RegistryDiscoveryProtocol.requests.count, 1)
        try await click("下载并查看", in: window)
        try await InstallerUIFixture.wait { installer.review != nil }
        XCTAssertEqual(RegistryDiscoveryProtocol.requests.count, 2)
        XCTAssertEqual(installer.review?.permissions, [.readClipboard, .writeClipboard])
        XCTAssertEqual(f.base.starts.value, 0)
        let before = await f.base.manager.plugins()
        XCTAssertTrue(before.isEmpty)
        try await settle(preview)
        try screenshot(preview, name: "registry-preview")
        try await click("安装插件", in: preview)
        try await InstallerUIFixture.wait { installer.installedID == f.entry.id && !installer.isBusy }
        let records = await f.base.manager.plugins()
        XCTAssertFalse(try XCTUnwrap(records.first).isEnabled)
        let validated = await f.base.manager.validatedPackage(id: f.entry.id)
        let states = try f.base.permissions.snapshot(package: XCTUnwrap(validated)).states
        XCTAssertTrue(states.values.allSatisfy { $0 == .requested })
        XCTAssertEqual(f.base.starts.value, 0)
        XCTAssertEqual(try f.base.stagedCount(), 0)
        try await settle(preview)
        try screenshot(preview, name: "registry-installed-disabled")
    }

    private func panel(width: CGFloat, height: CGFloat) -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false
        return panel
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
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        // Match the button label exactly: the idle instructions also mention
        // “刷新目录”, so a substring match would click the explanatory paragraph.
        let matches = (request.results ?? []).filter { $0.topCandidates(1).first?.string == label }
        let bounds = try XCTUnwrap(matches.min { $0.boundingBox.minY < $1.boundingBox.minY }, "Missing button \(label)").boundingBox
        let point = CGPoint(x: bounds.midX * view.bounds.width,
                            y: (view.isFlipped ? 1 - bounds.midY : bounds.midY) * view.bounds.height)
        let location = view.convert(point, to: nil)
        let events = try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { kind in
            try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(events[1], atStart: true)
        NSApp.sendEvent(events[0])
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking, dequeue: true) {
            NSApp.sendEvent(up)
        }
    }

    private func screenshot(_ window: NSWindow, name: String) throws {
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("dynamic-island-t40-\(name).png")
        try png.write(to: path)
        print("T40_SCREENSHOT=\(path.path)")
    }
}

private nonisolated final class RegistryDiscoveryProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var catalog = Data()
    nonisolated(unsafe) private static var archive = Data()
    nonisolated(unsafe) private static var hold = false
    nonisolated(unsafe) private static var seen: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { seen } }
    static func configure(catalog nextCatalog: Data, archive nextArchive: Data, holdArchive: Bool = false) {
        lock.withLock { catalog = nextCatalog; archive = nextArchive; hold = holdArchive; seen = [] }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let state = Self.lock.withLock { () -> (Data, Bool) in
            Self.seen.append(request)
            let isCatalog = request.url?.host == "raw.githubusercontent.com"
            return (isCatalog ? Self.catalog : Self.archive, !isCatalog && Self.hold)
        }
        if state.1 { return }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: state.0)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
