import AppKit
import SwiftUI
import XCTest
@testable import DynamicIsland

/// Native monitor bounds route each gesture to one navigation level only.
@MainActor
final class SettingsPagingTests: XCTestCase {
    func testSidebarAndDetailNavigateTheCorrectLevelWithoutCrossingBoundaries() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        try await settle(fixture.window)
        XCTAssertEqual(monitors(in: fixture.window).count, 2)

        for tab in [AppSettingsTab.appearance, .calendar, .plugins, .about] {
            try await step(1, at: .sidebar, in: fixture.window)
            XCTAssertEqual(fixture.model.selectedTab, tab)
            XCTAssertEqual(fixture.model.pluginSection, .installed)
        }
        try await step(1, at: .sidebar, in: fixture.window)
        XCTAssertEqual(fixture.model.selectedTab, .about, "The last tab does not wrap.")
        try await step(-1, at: .detail, in: fixture.window)
        XCTAssertEqual(fixture.model.selectedTab, .plugins)
        XCTAssertEqual(fixture.model.pluginSection, .installed)

        try await step(1, at: .detail, in: fixture.window)
        XCTAssertEqual(fixture.model.selectedTab, .plugins, "Plugin paging must not also change the main tab.")
        XCTAssertEqual(fixture.model.pluginSection, .discover)
        try await step(1, at: .detail, in: fixture.window)
        XCTAssertEqual(fixture.model.pluginSection, .diagnostics)
        try await step(1, at: .detail, in: fixture.window)
        XCTAssertEqual(fixture.model.pluginSection, .diagnostics,
                       "An idle installer is not a visible plugin page.")
        try await step(-1, at: .sidebar, in: fixture.window)
        XCTAssertEqual(fixture.model.selectedTab, .calendar)
        XCTAssertEqual(fixture.model.pluginSection, .diagnostics,
                       "Main navigation keeps the selected plugin subpage.")
        try await step(-1, at: .sidebar, in: fixture.window)
        try await step(-1, at: .sidebar, in: fixture.window)
        XCTAssertEqual(fixture.model.selectedTab, .general)
        try await step(-1, at: .sidebar, in: fixture.window)
        XCTAssertEqual(fixture.model.selectedTab, .general, "The first tab does not wrap.")
    }

    func testPagingExcludesAppearanceAndHomeDefaultPickers() async throws {
        let fixture = try makeFixture()
        defer { fixture.close() }
        fixture.model.musicProviders = OptionalMusicProviderRegistry(defaults: fixture.defaults)
        for tab in [AppSettingsTab.general, .appearance] {
            fixture.model.selectedTab = tab
            try await settle(fixture.window)
            let monitor = try singleEligibleMonitor(at: .detail, in: fixture.window)
            XCTAssertFalse(monitor.exclusionRects.isEmpty, "Value pickers must publish paging exclusions.")
            for rect in monitor.exclusionRects {
                let point = monitor.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
                XCTAssertFalse(monitor.isGestureEligible(at: point, in: fixture.window),
                               "Scrolling a settings value control must not change pages.")
                XCTAssertTrue(monitors(in: fixture.window).allSatisfy {
                    !$0.isGestureEligible(at: point, in: fixture.window)
                })
            }
        }
    }

    func testPluginSwipesPreserveThePendingInstallerReviewAndNeverRunActions() async throws {
        let installation = try await InstallerUIFixture.make()
        defer { installation.cleanup() }
        let installer = PluginInstallerModel(installer: installation.installer)
        let imported = await installer.importArchive(try installation.archive(version: "1.0.0"))
        XCTAssertTrue(imported)
        let review = try XCTUnwrap(installer.review)
        let fixture = try makeFixture(selectedTab: .plugins, pluginSection: .install, installer: installer)
        defer { fixture.close() }
        try await settle(fixture.window)

        try await step(-1, at: .detail, in: fixture.window)
        XCTAssertEqual(fixture.model.pluginSection, .diagnostics)
        try await step(1, at: .detail, in: fixture.window)
        XCTAssertEqual(fixture.model.pluginSection, .install)
        try await step(1, at: .detail, in: fixture.window)
        XCTAssertEqual(fixture.model.pluginSection, .install)
        try await step(1, at: .sidebar, in: fixture.window)
        XCTAssertEqual(fixture.model.selectedTab, .about)
        try await step(-1, at: .sidebar, in: fixture.window)
        XCTAssertEqual(fixture.model.selectedTab, .plugins)
        XCTAssertEqual(fixture.model.pluginSection, .install)
        XCTAssertEqual(installer.review, review)
        XCTAssertTrue(installer.hasPendingImport)
        XCTAssertEqual(try installation.stagedCount(), 1)
        XCTAssertEqual(installation.starts.value, 0)
    }

    private enum Region: Equatable { case sidebar, detail }

    private func makeFixture(selectedTab: AppSettingsTab = .general,
                             pluginSection: AppPluginSettingsSection = .installed,
                             installer: PluginInstallerModel? = nil) throws -> SettingsPagingFixture {
        let suite = "SettingsPagingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppSettingsModel(selectedTab: selectedTab, pluginSection: pluginSection,
                                     pluginInstallerModel: installer)
        model.homeSettings = IslandHomeSettings(defaults: defaults)
        let window = NSPanel(contentRect: CGRect(origin: .zero, size: AppSettingsView.minimumContentSize),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.contentView = NSHostingView(rootView: AppSettingsView(model: model,
            onImport: { XCTFail("Paging must not import a plugin.") },
            onDownload: { _ in XCTFail("Paging must not download a plugin.") },
            onCancelInstall: { XCTFail("Paging must not cancel installation.") },
            onShowIsland: { XCTFail("Paging must not show the island.") },
            onHideIsland: { XCTFail("Paging must not hide the island.") },
            onCopyDiagnosticInfo: { XCTFail("Paging must not copy diagnostics.") })
            .defaultAppStorage(defaults))
        window.center()
        window.orderFrontRegardless()
        return .init(window: window, model: model, defaults: defaults, suite: suite)
    }

    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(100))
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
    }

    private func monitors(in window: NSWindow) -> [IslandHomeScrollMonitorView] {
        func collect(_ view: NSView) -> [IslandHomeScrollMonitorView] {
            let current = (view as? IslandHomeScrollMonitorView).map { [$0] } ?? []
            return current + view.subviews.flatMap(collect)
        }
        return window.contentView.map(collect) ?? []
    }

    private func singleEligibleMonitor(at region: Region, in window: NSWindow) throws -> IslandHomeScrollMonitorView {
        let content = try XCTUnwrap(window.contentView)
        let topPoint = CGPoint(x: region == .sidebar ? 80 : 650, y: 600)
        let point = CGPoint(x: topPoint.x, y: content.isFlipped ? topPoint.y : content.bounds.height - topPoint.y)
        let windowPoint = content.convert(point, to: nil)
        let eligible = monitors(in: window).filter { $0.isGestureEligible(at: windowPoint, in: window) }
        XCTAssertEqual(eligible.count, 1, "Sidebar and detail scopes must never both handle one pointer location.")
        return try XCTUnwrap(eligible.first)
    }

    private func step(_ offset: Int, at region: Region, in window: NSWindow) async throws {
        try singleEligibleMonitor(at: region, in: window).onStep?(offset)
        try await settle(window)
    }
}

@MainActor
private struct SettingsPagingFixture {
    let window: NSWindow
    let model: AppSettingsModel
    let defaults: UserDefaults
    let suite: String

    func close() {
        window.close()
        defaults.removePersistentDomain(forName: suite)
    }
}
