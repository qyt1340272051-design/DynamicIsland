import AppKit
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandCoverGlassTests: XCTestCase {
    func testRealIslandChangesBackgroundWithArtworkAndRestoresClassicForOtherSurfaces() async throws {
        let suite = "IslandCoverGlassTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = MusicActivityTestService(info: .empty)
        let model = makeMusicActivityTestModel(music: service)
        let runtime = IslandActivityRuntime(viewModel: model)
        defer { runtime.shutdownPlugins() }
        await service.setInfo(track(artwork: artwork(.red)))
        await model.refreshNowPlaying()
        model.setHovering(true)
        let size = model.displayLayout.panelSize
        let hosting = NSHostingView(rootView: IslandView(viewModel: model, activityRuntime: runtime)
            .defaultAppStorage(defaults).environment(\.colorScheme, .dark))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }

        let classic = try await capture(hosting, name: "classic")
        assertBlack(backgroundPixel(classic, model: model, runtime: runtime))
        defaults.set(IslandAppearance.coverGlass.rawValue, forKey: IslandAppearance.defaultsKey)
        let red = try await capture(hosting, name: "red-expanded")
        let redPixel = backgroundPixel(red, model: model, runtime: runtime)
        XCTAssertGreaterThan(redPixel.redComponent, redPixel.blueComponent + 0.12)

        // Same metadata and track identifier: artwork-only refresh must repaint
        // the persistent hosting view, with no hover or track-change dependency.
        await service.setInfo(track(artwork: artwork(.blue)))
        await model.refreshNowPlaying()
        let blue = try await capture(hosting, name: "blue-expanded")
        let bluePixel = backgroundPixel(blue, model: model, runtime: runtime)
        XCTAssertGreaterThan(bluePixel.blueComponent, bluePixel.redComponent + 0.12)

        await service.setInfo(track(artwork: paletteArtwork()))
        await model.refreshNowPlaying()
        _ = try await capture(hosting, name: "palette-expanded")
        model.setHovering(false)
        let compact = try await capture(hosting, name: "palette-compact")
        XCTAssertEqual(model.presentationState, .compact)
        // The far trailing wing contains no cover, so color here proves that
        // the background paints independently of the sharp cover thumbnail.
        let layout = runtime.compactLayout(forBaseSize: model.displayLayout.designCompactSize)
        let x = size.width / 2 + layout.centerOffset + layout.size.width / 2 - 10
        let color = pixel(compact, x: x, y: layout.size.height - 8, viewSize: size)
        XCTAssertGreaterThan(max(color.redComponent, color.greenComponent, color.blueComponent), 0.04)

        model.setHovering(true)
        model.selectExpandedSurface(.fileTray)
        let tray = try await capture(hosting, name: "tray")
        assertBlack(backgroundPixel(tray, model: model, runtime: runtime))
        model.selectExpandedSurface(.music)
        await service.setInfo(track(artwork: nil))
        await model.refreshNowPlaying()
        let missing = try await capture(hosting, name: "missing-artwork")
        assertBlack(backgroundPixel(missing, model: model, runtime: runtime))
        await service.setInfo(track(artwork: Data([0, 1, 2, 3])))
        await model.refreshNowPlaying()
        let invalid = try await capture(hosting, name: "invalid-artwork")
        assertBlack(backgroundPixel(invalid, model: model, runtime: runtime))

        await service.setInfo(track(artwork: artwork(.red)))
        await model.refreshNowPlaying()
        defaults.set(IslandAppearance.classic.rawValue, forKey: IslandAppearance.defaultsKey)
        let restored = try await capture(hosting, name: "classic-restored")
        assertBlack(backgroundPixel(restored, model: model, runtime: runtime))
        XCTAssertEqual(hosting.frame.size, size)
    }

    func testGlassRetainsMultipleCoverColorsAndClipsToShell() async throws {
        let size = CGSize(width: 388, height: 152)
        let shape = IslandShellShape(size: size, topCornerRadius: 23, bottomCornerRadius: 23)
        let image = try XCTUnwrap(NSImage(data: XCTUnwrap(paletteArtwork())))
        let hosting = NSHostingView(rootView: IslandCoverGlass(artwork: image)
            .clipShape(shape).frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        let bitmap = try await capture(hosting, name: "glass-palette")
        let left = pixel(bitmap, x: 60, y: 70, viewSize: size)
        let right = pixel(bitmap, x: 328, y: 70, viewSize: size)
        XCTAssertGreaterThan(left.redComponent, left.blueComponent + 0.10)
        XCTAssertGreaterThan(right.blueComponent, right.redComponent + 0.10)
        XCTAssertLessThan(pixel(bitmap, x: 0, y: 0, viewSize: size).alphaComponent, 0.05)
        XCTAssertLessThan(max(left.redComponent, right.blueComponent), 0.8,
                          "The glass must darken even saturated covers for white controls.")
    }

    private func track(artwork: Data?) -> NowPlayingInfo {
        .init(isPlaying: true, title: "Midnight Reflections", artist: "Glass Sessions", album: "Afterglow",
              duration: 240, position: 84, trackIdentifier: "same-track", artworkData: artwork)
    }

    private func artwork(_ color: NSColor) -> Data? {
        NSImage(size: CGSize(width: 128, height: 128), flipped: false) { rect in
            color.setFill()
            NSBezierPath(rect: rect).fill()
            return true
        }.tiffRepresentation
    }

    private func paletteArtwork() -> Data? {
        NSImage(size: CGSize(width: 128, height: 128), flipped: false) { rect in
            NSGradient(colors: [.systemOrange, .systemPink, .systemBlue])?.draw(in: rect, angle: 0)
            return true
        }.tiffRepresentation
    }

    private func capture<Content: View>(_ view: NSHostingView<Content>, name: String) async throws -> NSBitmapImageRep {
        try await Task.sleep(for: .milliseconds(700))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["DI_COVER_GLASS_EVIDENCE_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("\(name).png"))
        }
        return bitmap
    }

    private func backgroundPixel(_ bitmap: NSBitmapImageRep, model: IslandViewModel,
                                 runtime: IslandActivityRuntime) -> NSColor {
        let shell = model.displayLayout.scaledExpanded(runtime.expandedShellSize)
        return pixel(bitmap, x: model.displayLayout.panelSize.width / 2 + shell.width * 0.25,
                     y: shell.height - 5, viewSize: model.displayLayout.panelSize)
    }

    private func pixel(_ bitmap: NSBitmapImageRep, x: CGFloat, y: CGFloat, viewSize: CGSize) -> NSColor {
        bitmap.colorAt(x: Int(x * CGFloat(bitmap.pixelsWide) / viewSize.width),
                       y: Int(y * CGFloat(bitmap.pixelsHigh) / viewSize.height))?.usingColorSpace(.deviceRGB) ?? .clear
    }

    private func assertBlack(_ color: NSColor, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(max(color.redComponent, color.greenComponent, color.blueComponent), 0.025,
                          file: file, line: line)
        XCTAssertGreaterThan(color.alphaComponent, 0.95, file: file, line: line)
    }
}
