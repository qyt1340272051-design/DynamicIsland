import AppKit
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandFrostedGlassTests: XCTestCase {
    func testNativeBackdropFollowsCompactExpandedAndAllSurfacesWithoutTakingInput() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else {
            throw XCTSkip("Native transparency is disabled by the current system accessibility preference.")
        }
        let suite = "IslandFrostedGlassTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(IslandAppearance.frostedGlass.rawValue, forKey: IslandAppearance.defaultsKey)
        let model = IslandViewModel.preview()
        let runtime = IslandActivityRuntime(viewModel: model)
        defer { runtime.shutdownPlugins() }
        let hosting = NSHostingView(rootView: IslandView(viewModel: model, activityRuntime: runtime)
            .defaultAppStorage(defaults))
        hosting.frame = CGRect(origin: .zero, size: model.displayLayout.panelSize)
        let window = makeWindow(hosting)
        defer { window.close() }

        try await settle(hosting)
        let effect = try XCTUnwrap(effects(in: hosting).first)
        XCTAssertEqual(effects(in: hosting).count, 1)
        XCTAssertEqual(effect.material, .hudWindow)
        XCTAssertEqual(effect.blendingMode, .behindWindow)
        XCTAssertEqual(effect.state, .active)
        XCTAssertEqual(effect.appearance?.name, .darkAqua)
        XCTAssertNil(effect.hitTest(CGPoint(x: effect.bounds.midX, y: 10)))
        try assertMask(effect, shellSize: model.displayLayout.compactSize, compact: true)

        model.setHovering(true)
        for surface in [IslandExpandedSurface.music, .fileTray, .tools, .utilities] {
            model.selectExpandedSurface(surface)
            try await settle(hosting)
            let current = try XCTUnwrap(effects(in: hosting).first)
            XCTAssertTrue(current === effect, "Surface switches must reuse the native backdrop.")
            try assertMask(current, shellSize: model.displayLayout.scaledExpanded(runtime.expandedShellSize), compact: false)
        }
        model.setHovering(false)
        try await settle(hosting)
        try assertMask(effect, shellSize: model.displayLayout.compactSize, compact: true)

        for appearance in [IslandAppearance.classic, .coverGlass, .coverGlow] {
            defaults.set(appearance.rawValue, forKey: IslandAppearance.defaultsKey)
            try await settle(hosting)
            XCTAssertTrue(effects(in: hosting).isEmpty, "Other styles must remove the native desktop blur.")
        }
    }

    func testReducedTransparencyUsesOpaqueBackgroundAndRestoresEffect() async throws {
        let model = IslandViewModel.preview()
        func root(reduced: Bool) -> some View {
            IslandFrostedGlassSurface(shape: .init(size: model.displayLayout.compactSize,
                topCornerRadius: 0, bottomCornerRadius: model.displayLayout.compactSize.height / 2),
                reduceTransparency: reduced)
        }
        let hosting = NSHostingView(rootView: root(reduced: true))
        hosting.frame = CGRect(origin: .zero, size: model.displayLayout.panelSize)
        let window = makeWindow(hosting)
        defer { window.close() }
        try await settle(hosting)
        XCTAssertTrue(effects(in: hosting).isEmpty)
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let center = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 8)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(center.alphaComponent, 0.95)
        XCTAssertLessThan(max(center.redComponent, center.greenComponent, center.blueComponent), 0.025)
        hosting.rootView = root(reduced: false)
        try await settle(hosting)
        XCTAssertEqual(effects(in: hosting).count, 1)
    }

    private func makeWindow<Content: View>(_ hosting: NSHostingView<Content>) -> NSPanel {
        let window = NSPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        return window
    }

    private func settle(_ view: NSView) async throws {
        try await Task.sleep(for: .milliseconds(650))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    private func effects(in view: NSView) -> [IslandFrostedGlass.EffectView] {
        (view as? IslandFrostedGlass.EffectView).map { [$0] } ?? view.subviews.flatMap { effects(in: $0) }
    }

    private func assertMask(_ view: IslandFrostedGlass.EffectView, shellSize: CGSize, compact: Bool,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let mask = try XCTUnwrap(view.maskImage, file: file, line: line)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(mask.tiffRepresentation)), file: file, line: line)
        func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            bitmap.colorAt(x: Int(x / view.bounds.width * CGFloat(bitmap.pixelsWide)),
                           y: Int(y / view.bounds.height * CGFloat(bitmap.pixelsHigh)))?.alphaComponent ?? -1
        }
        XCTAssertGreaterThan(alpha(view.bounds.midX, 4), 0.95, file: file, line: line)
        XCTAssertGreaterThan(alpha(view.bounds.midX, shellSize.height - 3), 0.95, file: file, line: line)
        XCTAssertLessThan(alpha(view.bounds.midX, shellSize.height + 4), 0.05,
                          "Material must not blur the panel's clear area below the shell.", file: file, line: line)
        let edgeX = view.bounds.midX - shellSize.width / 2 + 1
        if compact {
            XCTAssertGreaterThan(alpha(edgeX, 1), 0.9, "Compact top corners must stay square.", file: file, line: line)
        } else {
            XCTAssertLessThan(alpha(edgeX, 1), 0.05, "Expanded top corners must be rounded.", file: file, line: line)
        }
        XCTAssertLessThan(alpha(edgeX, shellSize.height - 1), 0.05,
                          "Bottom corners must be rounded in both states.", file: file, line: line)
    }
}
