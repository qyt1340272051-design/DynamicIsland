import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Vision
import XCTest
@testable import DynamicIsland

@MainActor
final class AppSettingsTests: XCTestCase {
    func testAutomaticMusicSourceStatusUpdatesWithoutAManualPlayerPicker() async throws {
        try requireUnlockedSession()
        let providers = OptionalMusicProviderRegistry()
        let model = AppSettingsModel()
        model.musicProviders = providers
        let window = makeWindow()
        window.contentView = NSHostingView(rootView: AppSettingsView(model: model,
            onImport: {}, onDownload: { _ in }, onCancelInstall: {},
            onShowIsland: {}, onHideIsland: {}, onCopyDiagnosticInfo: {}))
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(AppSettingsView.minimumContentSize)
        let windowNumber = window.windowNumber
        for (status, expected, evidence) in [
            (MusicSourceStatus.detecting, "正在识别音源", "detecting"),
            (.active("Spotify"), "当前音源：Spotify", "spotify"),
            (.unavailable("QQ 音乐"), "尚未就绪", "unavailable"),
            (.unsupported, "当前音源暂不支持", "unsupported"),
            (.failed, "暂时无法识别音源", "failed"),
            (.idle, "未检测到活动音源", "idle")
        ] {
            providers.updateSourceStatus(status)
            try await settle(window)
            let rendered = try renderedText(window, evidenceName: "automatic-source-\(evidence)")
            let normalized = rendered.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "：", with: ":")
            XCTAssertTrue(normalized.contains(expected.replacingOccurrences(of: "：", with: ":")), rendered)
            XCTAssertTrue(rendered.contains("自动识别音源"), rendered)
            XCTAssertFalse(rendered.contains("播放来源"), "The source is status text, not a manual choice.")
            XCTAssertEqual(window.windowNumber, windowNumber)
            XCTAssertEqual(model.selectedTab, .general)
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let controls = descendants(try XCTUnwrap(window.contentView))
        XCTAssertFalse(controls.contains { $0 is NSPopUpButton }, "The music source must not offer a manual app picker.")
    }

    func testHomeDefaultPagePickerAppliesAndPersistsAcrossSettingsViews() async throws {
        try requireUnlockedSession()
        let suite = "HomeDefaultPageSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppSettingsModel()
        model.musicProviders = OptionalMusicProviderRegistry()
        model.homeSettings = IslandHomeSettings(defaults: defaults)
        let window = makeWindow()
        func installSettings() {
            window.contentView = NSHostingView(rootView: AppSettingsView(model: model,
                onImport: {}, onDownload: { _ in }, onCancelInstall: {},
                onShowIsland: {}, onHideIsland: {}, onCopyDiagnosticInfo: {}))
        }
        installSettings()
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(AppSettingsView.minimumContentSize)
        try await settle(window)
        let initial = try renderedText(window, evidenceName: "home-default-page-music")
        for label in ["音乐", "日历", "课程", "会议"] { XCTAssertTrue(initial.contains(label), initial) }
        try await clickHomeDefaultLayer(.courses, in: window)
        XCTAssertEqual(model.homeSettings?.defaultLayer, .courses)
        XCTAssertEqual(IslandHomeSettings(defaults: defaults).defaultLayer, .courses)

        model.homeSettings = IslandHomeSettings(defaults: defaults)
        installSettings()
        try await settle(window)
        XCTAssertEqual(model.homeSettings?.defaultLayer, .courses)
        try await clickHomeDefaultLayer(.meetings, in: window)
        XCTAssertEqual(model.homeSettings?.defaultLayer, .meetings)
        XCTAssertEqual(IslandHomeSettings(defaults: defaults).defaultLayer, .meetings)
        _ = try renderedText(window, evidenceName: "home-default-page-meetings")
    }

    func testHomeLayerButtonToggleAppliesAndPersistsAcrossSettingsViews() async throws {
        try requireUnlockedSession()
        let suite = "HomeLayerSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IslandHomeSettings(defaults: defaults)
        XCTAssertTrue(settings.showsLayerButtons)
        let model = AppSettingsModel()
        model.homeSettings = settings
        let window = makeWindow()
        func installSettings() {
            window.contentView = NSHostingView(rootView: AppSettingsView(model: model,
                onImport: {}, onDownload: { _ in }, onCancelInstall: {},
                onShowIsland: {}, onHideIsland: {}, onCopyDiagnosticInfo: {}))
        }
        installSettings()
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(AppSettingsView.minimumContentSize)
        try await settle(window)
        XCTAssertTrue(try renderedText(window, evidenceName: "home-layer-buttons-visible").contains("显示主页选层按钮"))
        try await click("显示主页选层按钮", in: window, trailingSwitch: true)
        try await settle(window)
        XCTAssertFalse(settings.showsLayerButtons)

        let restored = IslandHomeSettings(defaults: defaults)
        XCTAssertFalse(restored.showsLayerButtons)
        model.homeSettings = restored
        installSettings()
        try await settle(window)
        try await click("显示主页选层按钮", in: window, trailingSwitch: true)
        try await settle(window)
        XCTAssertTrue(restored.showsLayerButtons)
        XCTAssertTrue(IslandHomeSettings(defaults: defaults).showsLayerButtons)
    }

    func testAppearanceSwitchPersistsAcrossSettingsViews() async throws {
        try requireUnlockedSession()
        let suite = "AppearanceSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppSettingsModel(selectedTab: .appearance)
        let window = makeWindow()
        func installSettings() {
            window.contentView = NSHostingView(rootView: AppSettingsView(model: model,
                onImport: {}, onDownload: { _ in }, onCancelInstall: {},
                onShowIsland: {}, onHideIsland: {}, onCopyDiagnosticInfo: {})
                .defaultAppStorage(defaults))
        }
        installSettings()
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(AppSettingsView.minimumContentSize)
        try await settle(window)
        try await click("封面流光", in: window)
        try await settle(window)
        XCTAssertEqual(defaults.string(forKey: IslandAppearance.defaultsKey), IslandAppearance.coverGlass.rawValue)
        installSettings()
        try await settle(window)
        let restored = try renderedText(window, evidenceName: "cover-glass-restored")
        XCTAssertTrue(restored.contains("磨砂玻璃"), restored)
        try await click("透明毛玻璃", in: window)
        try await settle(window)
        XCTAssertEqual(defaults.string(forKey: IslandAppearance.defaultsKey), IslandAppearance.frostedGlass.rawValue)
        installSettings()
        try await settle(window)
        let frosted = try renderedText(window, evidenceName: "frosted-glass-restored")
        XCTAssertTrue(frosted.contains("后方窗口"), frosted)
        try await click("封面光晕", in: window)
        try await settle(window)
        XCTAssertEqual(defaults.string(forKey: IslandAppearance.defaultsKey), IslandAppearance.coverGlow.rawValue)
        installSettings()
        try await settle(window)
        let glow = try renderedText(window, evidenceName: "cover-glow-restored")
        XCTAssertTrue(glow.contains("渐变融入默认黑色"), glow)
        try await click("默认外观", in: window)
        try await settle(window)
        XCTAssertEqual(defaults.string(forKey: IslandAppearance.defaultsKey), IslandAppearance.classic.rawValue)
    }

    func testNativeTabsAndPageActionsFitTheMinimumSettingsWindow() async throws {
        try requireUnlockedSession()
        let model = AppSettingsModel()
        model.musicProviders = OptionalMusicProviderRegistry()
        var shows = 0
        var hides = 0
        var copied = 0
        let window = makeWindow()
        window.contentView = NSHostingView(rootView: AppSettingsView(model: model,
            onImport: { XCTFail("Changing settings tabs must not import a plugin.") },
            onDownload: { _ in XCTFail("Changing settings tabs must not download a plugin.") },
            onCancelInstall: { XCTFail("Changing settings tabs must not cancel installation.") },
            onShowIsland: { shows += 1 }, onHideIsland: { hides += 1 },
            onCopyDiagnosticInfo: { copied += 1 }))
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(AppSettingsView.minimumContentSize)
        let originalWindowNumber = window.windowNumber
        try await settle(window)

        let general = try renderedText(window, evidenceName: "general-minimum")
        try assertSidebarAlignment(in: window)
        for label in ["通用", "外观", "日历与提醒", "插件", "关于", "音乐播放器", "自动识别音源", "Apple Music", "显示灵动岛", "隐藏灵动岛"] {
            XCTAssertTrue(general.contains(label), "Missing minimum-size settings control \(label): \(general)")
        }
        try await click("显示灵动岛", in: window)
        try await click("隐藏灵动岛", in: window)
        XCTAssertEqual(shows, 1)
        XCTAssertEqual(hides, 1)

        try await click("外观", in: window, preferTopmost: true)
        XCTAssertEqual(model.selectedTab, .appearance)
        try await settle(window)
        let appearance = try renderedText(window, evidenceName: "appearance-minimum")
        XCTAssertTrue(appearance.contains("默认外观"), appearance)
        XCTAssertTrue(appearance.contains("查看灵动岛"), appearance)
        try await click("查看灵动岛", in: window)
        XCTAssertEqual(shows, 2)

        try await click("插件", in: window, preferTopmost: true)
        XCTAssertEqual(model.selectedTab, .plugins)
        try await settle(window)
        let plugins = try renderedText(window, evidenceName: "initializing-minimum")
        XCTAssertTrue(plugins.contains("插件功能正在准备"), plugins)
        XCTAssertTrue(plugins.contains("导入插件"), plugins)

        try await click("关于", in: window, preferTopmost: true)
        XCTAssertEqual(model.selectedTab, .about)
        try await settle(window)
        let about = try renderedText(window, evidenceName: "about-minimum")
        for label in ["版本", "构建", "复制诊断信息"] { XCTAssertTrue(about.contains(label), about) }
        try await click("复制诊断信息", in: window)
        XCTAssertEqual(copied, 1)

        try await click("通用", in: window, preferTopmost: true)
        XCTAssertEqual(model.selectedTab, .general)
        XCTAssertEqual(window.windowNumber, originalWindowNumber)
        XCTAssertEqual(window.contentView?.bounds.size, AppSettingsView.minimumContentSize)
        XCTAssertTrue(window.isVisible)
    }

    func testNativePluginDiscoveryAndPendingReviewUseSharedModelsWithoutImplicitRequests() async throws {
        try requireUnlockedSession()
        let fixture = try await RegistryUIFixture.make()
        defer { fixture.base.cleanup() }
        let loader = AppSettingsCatalogLoadWitness()
        let catalog = fixture.catalog
        let registry = fixture.discovery(loader: { _ in await loader.load(catalog) })
        let diagnosticsStore = PluginDiagnosticsStore()
        let diagnostics = PluginDiagnosticsModel(manager: fixture.base.manager, lifecycle: fixture.base.lifecycle,
            diagnostics: diagnosticsStore)
        let extensions = PluginExtensionsModel(manager: fixture.base.manager, lifecycle: fixture.base.lifecycle,
            permissions: fixture.base.permissions, diagnostics: diagnosticsStore, diagnosticsModel: diagnostics)
        let model = AppSettingsModel(selectedTab: .plugins, pluginExtensionsModel: extensions,
            pluginRegistryModel: registry, pluginDiagnosticsModel: diagnostics, pluginInstallerModel: fixture.installer)
        let window = makeWindow()
        window.contentView = NSHostingView(rootView: AppSettingsView(model: model,
            onImport: {}, onDownload: { entry in
                model.pluginSection = .install
                Task { _ = await registry.download(entry) }
            }, onCancelInstall: {
                Task {
                    if await fixture.installer.cancel() { model.pluginSection = .installed }
                }
            }, onShowIsland: {}, onHideIsland: {}, onCopyDiagnosticInfo: {}))
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(AppSettingsView.minimumContentSize)
        try await settle(window)

        let installed = try renderedText(window, evidenceName: "plugins-installed-minimum")
        try assertPluginHeaderAlignment(in: window)
        for label in ["插件管理", "已安装", "发现", "诊断", "导入插件"] {
            XCTAssertTrue(installed.contains(label), installed)
        }
        try await click("发现", in: window, preferTopmost: true)
        XCTAssertEqual(model.pluginSection, .discover)
        try await settle(window)
        let discovery = try renderedText(window, evidenceName: "plugins-discover-minimum")
        XCTAssertTrue(discovery.contains("不会自动联网"), discovery)
        XCTAssertTrue(discovery.contains("刷新目录"), discovery)
        let initialLoads = await loader.calls
        XCTAssertEqual(initialLoads, 0)
        XCTAssertFalse(fixture.installer.hasPendingImport)

        try await click("刷新目录", in: window)
        try await InstallerUIFixture.wait { registry.phase == .loaded && registry.entries.count == 1 }
        let explicitLoads = await loader.calls
        XCTAssertEqual(explicitLoads, 1)
        try await click("下载并查看", in: window)
        try await InstallerUIFixture.wait { fixture.installer.review != nil }
        let review = try XCTUnwrap(fixture.installer.review)
        XCTAssertEqual(model.pluginSection, .install)
        XCTAssertEqual(try fixture.base.stagedCount(), 1)
        XCTAssertEqual(fixture.base.starts.value, 0)
        try await settle(window)
        let preview = try renderedText(window, evidenceName: "plugins-install-minimum")
        for label in ["Installer Fixture", "安装插件", "取消", "安装不会授予权限"] {
            XCTAssertTrue(preview.contains(label), "Embedded preview cropped \(label): \(preview)")
        }

        try await click("关于", in: window, preferTopmost: true)
        XCTAssertEqual(model.selectedTab, .about)
        try await click("插件", in: window, preferTopmost: true)
        XCTAssertEqual(model.selectedTab, .plugins)
        XCTAssertEqual(model.pluginSection, .install)
        XCTAssertTrue(model.pluginInstallerModel === fixture.installer)
        XCTAssertTrue(model.pluginRegistryModel === registry)
        XCTAssertTrue(model.pluginExtensionsModel === extensions)
        XCTAssertEqual(fixture.installer.review, review, "Tab changes must preserve the exact immutable review.")
        XCTAssertEqual(try fixture.base.stagedCount(), 1)
        try await click("取消", in: window)
        try await InstallerUIFixture.wait { !fixture.installer.hasPendingImport && model.pluginSection == .installed }
        XCTAssertEqual(try fixture.base.stagedCount(), 0)
        let records = await fixture.base.manager.plugins()
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(fixture.base.starts.value, 0)
        let finalLoads = await loader.calls
        XCTAssertEqual(finalLoads, 1)
    }

    func testLeavingEmbeddedDiscoveryCancelsRefreshAndRejectsTheLateCatalog() async throws {
        let fixture = try await RegistryUIFixture.make()
        defer { fixture.base.cleanup() }
        let gate = RegistryAsyncGate()
        let catalog = fixture.catalog
        let registry = fixture.discovery(loader: { _ in await gate.wait(); return catalog })
        let model = AppSettingsModel(selectedTab: .plugins, pluginSection: .discover,
            pluginRegistryModel: registry, pluginInstallerModel: fixture.installer)
        let window = makeWindow()
        window.contentView = NSHostingView(rootView: AppSettingsView(model: model,
            onImport: {}, onDownload: { _ in }, onCancelInstall: {},
            onShowIsland: {}, onHideIsland: {}, onCopyDiagnosticInfo: {}))
        defer { window.close() }
        window.orderFrontRegardless()
        try await settle(window)
        let refresh = Task { await registry.refresh() }
        try await InstallerUIFixture.wait { registry.phase == .loading }

        model.selectedTab = .about
        try await InstallerUIFixture.wait { registry.phase == .cancelling }
        await gate.release()
        await refresh.value

        XCTAssertEqual(registry.phase, .idle)
        XCTAssertTrue(registry.entries.isEmpty)
        XCTAssertNil(registry.errorMessage)
        XCTAssertFalse(fixture.installer.hasPendingImport)
    }

    func testWindowClosePreservesTheOriginalDelegatesVetoAndNotification() {
        let window = makeWindow()
        let original = AppSettingsWindowDelegateWitness()
        original.allowsClose = false
        window.delegate = original
        var closed = 0
        let coordinator = AppSettingsWindowCoordinator(installer: { nil }, onShowInstaller: {
            XCTFail("An idle settings window must not navigate to installation.")
        }, onClose: { closed += 1 })
        coordinator.attach(to: window)
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()

        window.performClose(nil)

        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(original.closeRequests, 1)
        XCTAssertEqual(original.closeNotifications, 0)
        XCTAssertEqual(closed, 0)

        original.allowsClose = true
        window.performClose(nil)

        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(original.closeRequests, 2)
        XCTAssertEqual(original.closeNotifications, 1)
        XCTAssertEqual(closed, 1)
        XCTAssertTrue(window.delegate === coordinator)
    }

    func testWindowCloseCancelsThePendingReviewBeforeClosing() async throws {
        let fixture = try await InstallerUIFixture.make()
        defer { fixture.cleanup() }
        let installer = PluginInstallerModel(installer: fixture.installer)
        let imported = await installer.importArchive(try fixture.archive(version: "1.0.0"))
        XCTAssertTrue(imported)
        XCTAssertEqual(try fixture.stagedCount(), 1)
        let window = makeWindow()
        let original = AppSettingsWindowDelegateWitness()
        window.delegate = original
        var installerPresentations = 0
        var closed = 0
        let coordinator = AppSettingsWindowCoordinator(installer: { installer }, onShowInstaller: {
            installerPresentations += 1
        }, onClose: { closed += 1 })
        coordinator.attach(to: window)
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()

        window.performClose(nil)

        XCTAssertTrue(window.isVisible, "Closing must await cleanup rather than hide a pending review.")
        XCTAssertEqual(installerPresentations, 1)
        XCTAssertEqual(original.closeRequests, 0)
        try await InstallerUIFixture.wait { !window.isVisible }
        XCTAssertFalse(installer.hasPendingImport)
        XCTAssertNil(installer.review)
        XCTAssertEqual(try fixture.stagedCount(), 0)
        XCTAssertEqual(fixture.starts.value, 0)
        XCTAssertEqual(original.closeRequests, 1)
        XCTAssertEqual(original.closeNotifications, 1)
        XCTAssertEqual(closed, 1)
        XCTAssertTrue(window.delegate === coordinator)
    }

    func testCleanupFailureKeepsTheWindowAndExactReviewVisibleUntilRetry() async throws {
        let fixture = try await InstallerUIFixture.make()
        defer { fixture.cleanup() }
        let handler = AppSettingsFirstCancelFailureInstaller(installer: fixture.installer)
        let installer = PluginInstallerModel(installer: handler)
        let imported = await installer.importArchive(try fixture.archive(version: "1.0.0"))
        XCTAssertTrue(imported)
        let review = try XCTUnwrap(installer.review)
        let window = makeWindow()
        var installerPresentations = 0
        var closed = 0
        let coordinator = AppSettingsWindowCoordinator(installer: { installer }, onShowInstaller: {
            installerPresentations += 1
        }, onClose: { closed += 1 })
        coordinator.attach(to: window)
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()

        window.performClose(nil)
        try await InstallerUIFixture.wait { installer.requiresCleanup && !installer.isBusy }

        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(installer.review, review)
        XCTAssertEqual(installer.errorCode, "cleanupFailed")
        XCTAssertEqual(try fixture.stagedCount(), 1)
        XCTAssertEqual(closed, 0)

        window.performClose(nil)
        try await InstallerUIFixture.wait { !window.isVisible }

        XCTAssertEqual(installerPresentations, 2)
        XCTAssertEqual(closed, 1)
        XCTAssertFalse(installer.hasPendingImport)
        XCTAssertEqual(try fixture.stagedCount(), 0)
        XCTAssertEqual(fixture.starts.value, 0)
        XCTAssertTrue(window.delegate === coordinator)
    }

    private func makeWindow() -> NSPanel {
        let window = NSPanel(contentRect: CGRect(origin: .zero, size: AppSettingsView.minimumContentSize),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.center()
        return window
    }

    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
    }

    private func requireUnlockedSession() throws {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session["CGSSessionScreenIsLocked"] as? Bool == true {
            throw XCTSkip("Real AppKit mouse input requires an unlocked macOS session.")
        }
    }

    private func clickHomeDefaultLayer(_ layer: IslandHomeLayer, in window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        try await settle(window)
        try await InstallerUIFixture.wait { window.isKeyWindow }
        let view = try XCTUnwrap(window.contentView)
        func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
        let expectedLabels = IslandHomeLayer.allCases.map(\.title)
        let picker = try XCTUnwrap(descendants(view).compactMap { $0 as? NSSegmentedControl }.first { control in
            control.segmentCount == expectedLabels.count
                && (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" } == expectedLabels
        }, "Missing native default-home-page picker")
        XCTAssertTrue(picker.isEnabled)
        XCTAssertFalse(picker.isHiddenOrHasHiddenAncestor)
        let index = try XCTUnwrap(expectedLabels.firstIndex(of: layer.title))
        // All four labels use the same two-glyph width, so the native control
        // assigns equal automatic segment widths. Click the rendered segment
        // rather than requiring Vision to split adjacent labels into words.
        let point = CGPoint(x: picker.bounds.minX + picker.bounds.width * (CGFloat(index) + 0.5)
                                / CGFloat(picker.segmentCount),
                            y: picker.bounds.midY)
        let location = picker.convert(point, to: nil)
        try sendClick(at: location, in: window)
        try await settle(window)
        XCTAssertEqual(picker.selectedSegment, index)
    }

    private func click(_ label: String, in window: NSWindow, preferTopmost: Bool = false,
                       trailingSwitch: Bool = false) async throws {
        window.makeKeyAndOrderFront(nil)
        try await settle(window)
        do {
            try await InstallerUIFixture.wait {
                if !window.isKeyWindow, window.attachedSheet == nil { window.makeKey() }
                return window.isKeyWindow
            }
        } catch {
            NativeWindowTestingDiagnostics.keyTimeout(window)
            throw error
        }
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try CompatibilityRenderingEvidence.bitmap(in: view)
        let image = try XCTUnwrap(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let isSidebarTab = preferTopmost && ["通用", "外观", "日历与提醒", "插件", "关于"].contains(label)
        let matches = (request.results ?? []).filter { observation in
            if isSidebarTab, observation.boundingBox.maxX * view.bounds.width >= 159 { return false }
            return observation.topCandidates(3).contains { candidate in
                // Vision can include the tab's SF Symbol in the same text
                // observation. Main navigation lives in the left sidebar;
                // plugin navigation uses the top row in the detail area.
                preferTopmost ? candidate.string.contains(label)
                    : candidate.string.filter(\.isLetter) == label.filter(\.isLetter)
            }
        }
        let sorted = matches.sorted { $0.boundingBox.midY < $1.boundingBox.midY }
        let match = try XCTUnwrap(preferTopmost ? sorted.last : sorted.first,
                                 "Missing visible control \(label)")
        let bounds = match.boundingBox
        var point = CGPoint(x: bounds.midX * view.bounds.width,
                            y: (view.isFlipped ? 1 - bounds.midY : bounds.midY) * view.bounds.height)
        if trailingSwitch {
            // macOS switch labels are passive. Locate the painted switch/knob
            // beside the recognized label instead of clicking the label text.
            let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
            let start = min(bitmap.pixelsWide - 1, Int(bounds.maxX * CGFloat(bitmap.pixelsWide) + 4 * scale))
            let end = min(bitmap.pixelsWide, start + Int(80 * scale))
            let row = min(bitmap.pixelsHigh - 1, max(0, Int((1 - bounds.midY) * CGFloat(bitmap.pixelsHigh))))
            let bright = (start..<end).filter { x in
                guard let color = bitmap.colorAt(x: x, y: row)?.usingColorSpace(.deviceRGB) else { return false }
                return color.alphaComponent > 0.5 && max(color.redComponent, color.greenComponent, color.blueComponent) > 0.65
            }
            let first = try XCTUnwrap(bright.first, "Missing visible switch beside \(label)")
            let last = try XCTUnwrap(bright.last)
            point.x = CGFloat(first + last) / 2 / scale
        }
        let location = view.convert(point, to: nil)
        try sendClick(at: location, in: window)
    }

    private func sendClick(at location: CGPoint, in window: NSWindow) throws {
        let events = try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { kind in
            try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: location, modifierFlags: [],
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

    private func navigationLabelFrames(in window: NSWindow) throws -> [(text: String, frame: CGRect, leadingGlyphCenter: CGFloat)] {
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try CompatibilityRenderingEvidence.bitmap(in: view)
        let image = try XCTUnwrap(bitmap.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).flatMap { observation -> [(text: String, frame: CGRect, leadingGlyphCenter: CGFloat)] in
            guard let candidate = observation.topCandidates(1).first else { return [] }
            // Measure the label glyphs alone: Vision sometimes recognizes an
            // adjacent SF Symbol as a prefix with a different visual width.
            return ["通用", "外观", "日历与提醒", "插件", "关于", "已安装", "发现", "诊断", "导入插件"].compactMap { title in
                guard let range = candidate.string.range(of: title),
                      let box = try? candidate.boundingBox(for: range),
                      let lastGlyph = try? candidate.boundingBox(for:
                        candidate.string.index(before: range.upperBound)..<range.upperBound) else { return nil }
                let bounds = box.boundingBox
                // Vision expands the first character's box into neighboring
                // whitespace for some two-character Chinese labels. Its final
                // glyph stays tight. Subtract the measured prefix advance to
                // compare first-glyph centers across labels of different length.
                let prefixWidth = (String(title.dropLast()) as NSString).size(withAttributes: [
                    .font: NSFont.preferredFont(forTextStyle: .body)
                ]).width
                return (title, CGRect(x: bounds.minX * view.bounds.width,
                    y: (1 - bounds.maxY) * view.bounds.height,
                    width: bounds.width * view.bounds.width, height: bounds.height * view.bounds.height),
                    lastGlyph.boundingBox.midX * view.bounds.width - prefixWidth)
            }
        }
    }

    private func assertSidebarAlignment(in window: NSWindow) throws {
        let labels = try navigationLabelFrames(in: window)
        let sidebar = try ["通用", "外观", "日历与提醒", "插件", "关于"].map { title in
            try XCTUnwrap(labels.first { $0.text.contains(title) && $0.frame.maxX < 159 },
                          "Missing sidebar label \(title)")
        }
        for label in sidebar {
            XCTAssertEqual(label.leadingGlyphCenter, sidebar[0].leadingGlyphCenter, accuracy: 2,
                           "Sidebar text is misaligned: \(label.text)")
        }
        let frames = sidebar.map(\.frame)
        for index in 1..<frames.count {
            XCTAssertEqual(frames[index].midY - frames[index - 1].midY, 40, accuracy: 3)
        }
    }

    private func assertPluginHeaderAlignment(in window: NSWindow) throws {
        let labels = try navigationLabelFrames(in: window)
        let frames = try ["已安装", "发现", "诊断"].map { title in
            try XCTUnwrap(labels.first { $0.text.contains(title) && $0.frame.maxY < 39 },
                          "Missing plugin header label \(title)").frame
        }
        let importFrame = try XCTUnwrap(labels.first { $0.text.contains("导入插件") && $0.frame.maxY < 39 }).frame
        for frame in frames {
            XCTAssertEqual(frame.midY, importFrame.midY, accuracy: 3)
        }
        for index in 1..<frames.count {
            XCTAssertEqual(frames[index].midX - frames[index - 1].midX, 82, accuracy: 3)
        }
        XCTAssertEqual(frames[0].midX, 160 + 16 + 38, accuracy: 3)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(window.contentView).bounds.width - importFrame.maxX, 16)
    }

    private func renderedText(_ window: NSWindow, evidenceName: String) throws -> String {
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try CompatibilityRenderingEvidence.bitmap(in: view)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("dynamic-island-settings-\(evidenceName).png")
        try png.write(to: path, options: .atomic)
        print("SETTINGS_SCREENSHOT=\(path.path)")
        let text = try CompatibilityRenderingEvidence.renderedText(in: view)
        print("SETTINGS_\(evidenceName.uppercased())_RENDERED_TEXT=\(text)")
        return text
    }
}

private actor AppSettingsCatalogLoadWitness {
    private(set) var calls = 0

    func load(_ catalog: PluginRegistryCatalog) -> PluginRegistryCatalog {
        calls += 1
        return catalog
    }
}

@MainActor
private final class AppSettingsWindowDelegateWitness: NSObject, NSWindowDelegate {
    var allowsClose = true
    private(set) var closeRequests = 0
    private(set) var closeNotifications = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeRequests += 1
        return allowsClose
    }

    func windowWillClose(_ notification: Notification) {
        closeNotifications += 1
    }
}

private actor AppSettingsFirstCancelFailureInstaller: PluginInstallationHandling {
    private let installer: PluginInstaller
    private var shouldFailCancel = true

    init(installer: PluginInstaller) { self.installer = installer }

    func prepare(archiveURL: URL) async throws -> PluginInstallReview {
        try await installer.prepare(archiveURL: archiveURL)
    }

    func cancel(_ review: PluginInstallReview) async throws {
        if shouldFailCancel {
            shouldFailCancel = false
            throw PluginInstallerError.cleanupFailed
        }
        try await installer.cancel(review)
    }

    func commit(_ review: PluginInstallReview) async throws -> PluginRecord {
        try await installer.commit(review)
    }

    func hasPendingCleanup() async -> Bool { await installer.hasPendingCleanup() }

    func retryCleanup() async throws { try await installer.retryCleanup() }
}
