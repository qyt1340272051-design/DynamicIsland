import AppKit
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandCoverGlowTests: XCTestCase {
    func testRealIslandRefreshesGlowWithArtworkAndReturnsToBlackOutsideMusic() async throws {
        let suite = "IslandCoverGlowTests.\(UUID().uuidString)"
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
        let window = makeWindow(hosting)
        defer { window.close() }

        let classic = try await capture(hosting, name: "classic")
        assertBlack(expandedBackgroundPixel(classic, model: model, runtime: runtime))
        defaults.set(IslandAppearance.coverGlow.rawValue, forKey: IslandAppearance.defaultsKey)
        let red = try await capture(hosting, name: "red-expanded")
        assertTint(expandedBackgroundPixel(red, model: model, runtime: runtime), red: true)
        assertBlack(expandedBackgroundPixel(red, model: model, runtime: runtime, far: true))

        // Update only the cover on the same track, keeping this hosting view
        // mounted so the test catches a stale decoded image or stale anchor.
        await service.setInfo(track(artwork: artwork(.blue)))
        await model.refreshNowPlaying()
        let blue = try await capture(hosting, name: "blue-expanded")
        assertTint(expandedBackgroundPixel(blue, model: model, runtime: runtime), red: false)
        assertBlack(expandedBackgroundPixel(blue, model: model, runtime: runtime, far: true))

        model.setHovering(false)
        let compact = try await capture(hosting, name: "blue-compact")
        XCTAssertEqual(model.presentationState, .compact)
        // Sample below the sharp thumbnail and waveform: light beside the
        // cover and black at the opposite wing must come from the background.
        assertTint(compactBackgroundPixel(compact, model: model, runtime: runtime), red: false)
        assertBlack(compactBackgroundPixel(compact, model: model, runtime: runtime, far: true))

        model.setDragging(true)
        let dragging = try await capture(hosting, name: "dragging")
        XCTAssertEqual(model.presentationState, .dragging)
        XCTAssertEqual(model.expandedSurface, .fileTray)
        assertBlack(expandedBackgroundPixel(dragging, model: model, runtime: runtime))
        model.setDragging(false)
        model.setHovering(true)
        model.selectExpandedSurface(.music)
        await service.setInfo(track(artwork: nil))
        await model.refreshNowPlaying()
        let missing = try await capture(hosting, name: "missing-artwork")
        assertBlack(expandedBackgroundPixel(missing, model: model, runtime: runtime))
        await service.setInfo(track(artwork: Data([0, 1, 2, 3])))
        await model.refreshNowPlaying()
        let invalid = try await capture(hosting, name: "invalid-artwork")
        assertBlack(expandedBackgroundPixel(invalid, model: model, runtime: runtime))

        await service.setInfo(track(artwork: artwork(.red)))
        await model.refreshNowPlaying()
        let recovered = try await capture(hosting, name: "red-recovered")
        assertTint(expandedBackgroundPixel(recovered, model: model, runtime: runtime), red: true)
        for (surface, name) in [(IslandExpandedSurface.fileTray, "tray"), (.utilities, "tools"), (.tools, "timer-expanded")] {
            model.selectExpandedSurface(surface)
            let otherSurface = try await capture(hosting, name: name)
            assertBlack(expandedBackgroundPixel(otherSurface, model: model, runtime: runtime))
        }

        model.timerTools.selectedMode = .stopwatch
        model.timerTools.startSelectedTimer(at: Date())
        defer { model.timerTools.resetSelectedTimer() }
        model.setHovering(false)
        let timer = try await capture(hosting, name: "timer-compact")
        XCTAssertEqual(model.compactTimerMode, .stopwatch)
        assertBlack(compactBackgroundPixel(timer, model: model, runtime: runtime))
        assertBlack(compactBackgroundPixel(timer, model: model, runtime: runtime, far: true))

        model.timerTools.resetSelectedTimer()
        model.setHovering(true)
        model.selectExpandedSurface(.music)
        let musicAgain = try await capture(hosting, name: "music-restored")
        assertTint(expandedBackgroundPixel(musicAgain, model: model, runtime: runtime), red: true)

        await service.setInfo(track(artwork: artwork(.white)))
        await model.refreshNowPlaying()
        let white = try await capture(hosting, name: "white-expanded")
        let whiteGlow = expandedBackgroundPixel(white, model: model, runtime: runtime)
        XCTAssertLessThan(max(whiteGlow.redComponent, whiteGlow.greenComponent, whiteGlow.blueComponent), 0.65,
                          "Bright covers must leave a dark background for white controls.")
        await service.setInfo(track(artwork: artwork(.black)))
        await model.refreshNowPlaying()
        let black = try await capture(hosting, name: "black-expanded")
        assertBlack(expandedBackgroundPixel(black, model: model, runtime: runtime))

        await service.setInfo(track(artwork: paletteArtwork()))
        await model.refreshNowPlaying()
        _ = try await capture(hosting, name: "palette-expanded")
        model.setHovering(false)
        _ = try await capture(hosting, name: "palette-compact")
        model.setHovering(true)
        defaults.set(IslandAppearance.classic.rawValue, forKey: IslandAppearance.defaultsKey)
        let restored = try await capture(hosting, name: "classic-restored")
        assertBlack(expandedBackgroundPixel(restored, model: model, runtime: runtime))
        XCTAssertEqual(hosting.frame.size, size)
    }

    func testGlowFallsOffAroundCoverPositionInAllDirectionsAndClipsToShell() async throws {
        let size = CGSize(width: 400, height: 260)
        let sourceRect = CGRect(x: 110, y: 90, width: 80, height: 80)
        let shape = IslandShellShape(size: size, topCornerRadius: 24, bottomCornerRadius: 24)
        let image = try XCTUnwrap(NSImage(data: XCTUnwrap(artwork(.red))))
        let hosting = NSHostingView(rootView: IslandCoverGlow(artwork: image, sourceRect: sourceRect)
            .clipShape(shape).frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = makeWindow(hosting)
        defer { window.close() }
        let bitmap = try await capture(hosting, name: "radial-red")
        let center = CGPoint(x: sourceRect.midX, y: sourceRect.midY)
        let centerColor = pixel(bitmap, at: center, viewSize: size)
        assertTint(centerColor, red: true)
        for direction in [CGVector(dx: -1, dy: 0), CGVector(dx: 1, dy: 0),
                          CGVector(dx: 0, dy: -1), CGVector(dx: 0, dy: 1)] {
            let near = CGPoint(x: center.x + direction.dx * 60, y: center.y + direction.dy * 60)
            let far = CGPoint(x: center.x + direction.dx * 120, y: center.y + direction.dy * 120)
            let nearColor = pixel(bitmap, at: near, viewSize: size)
            let farColor = pixel(bitmap, at: far, viewSize: size)
            assertTint(nearColor, red: true)
            XCTAssertGreaterThan(centerColor.redComponent, nearColor.redComponent + 0.015,
                                 "The light must fade away from the actual cover position.")
            XCTAssertGreaterThan(nearColor.redComponent, farColor.redComponent + 0.015,
                                 "All four directions must continue fading toward the black shell.")
        }
        assertBlack(pixel(bitmap, at: CGPoint(x: 380, y: center.y), viewSize: size))
        XCTAssertLessThan(pixel(bitmap, at: .zero, viewSize: size).alphaComponent, 0.05,
                          "Light must stay inside the rounded island shell.")
        XCTAssertLessThan(pixel(bitmap, at: CGPoint(x: size.width - 1, y: size.height - 1), viewSize: size)
            .alphaComponent, 0.05)
    }

    private func track(artwork: Data?) -> NowPlayingInfo {
        .init(isPlaying: true, title: "Midnight Reflections", artist: "Glow Sessions", album: "Afterglow",
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

    private func makeWindow<Content: View>(_ hosting: NSHostingView<Content>) -> NSWindow {
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        return window
    }

    private func capture<Content: View>(_ view: NSHostingView<Content>, name: String) async throws -> NSBitmapImageRep {
        try await Task.sleep(for: .milliseconds(700))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["DI_COVER_GLOW_EVIDENCE_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("\(name).png"))
        }
        return bitmap
    }

    private func expandedBackgroundPixel(_ bitmap: NSBitmapImageRep, model: IslandViewModel,
                                         runtime: IslandActivityRuntime, far: Bool = false) -> NSColor {
        let shell = model.displayLayout.scaledExpanded(runtime.expandedShellSize)
        let scale = model.displayLayout.expandedScale
        let left = (model.displayLayout.panelSize.width - shell.width) / 2
        let point = CGPoint(x: far ? left + shell.width - 48 * scale : left + 48 * scale,
                            y: shell.height - 6 * scale)
        return pixel(bitmap, at: point, viewSize: model.displayLayout.panelSize)
    }

    private func compactBackgroundPixel(_ bitmap: NSBitmapImageRep, model: IslandViewModel,
                                        runtime: IslandActivityRuntime, far: Bool = false) -> NSColor {
        let layout = runtime.compactLayout(forBaseSize: model.displayLayout.designCompactSize)
        let scale = model.displayLayout.scale
        let shell = model.displayLayout.scaled(layout.size)
        let left = model.displayLayout.panelSize.width / 2 + layout.centerOffset * scale - shell.width / 2
        let point = CGPoint(x: far ? left + shell.width - layout.trailingWidth * scale / 2
                                 : left + layout.leadingWidth * scale / 2,
                            y: shell.height - 3 * scale)
        return pixel(bitmap, at: point, viewSize: model.displayLayout.panelSize)
    }

    private func pixel(_ bitmap: NSBitmapImageRep, at point: CGPoint, viewSize: CGSize) -> NSColor {
        bitmap.colorAt(x: Int(point.x * CGFloat(bitmap.pixelsWide) / viewSize.width),
                       y: Int(point.y * CGFloat(bitmap.pixelsHigh) / viewSize.height))?
            .usingColorSpace(.deviceRGB) ?? .clear
    }

    private func assertTint(_ color: NSColor, red: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let dominant = red ? color.redComponent : color.blueComponent
        let opposite = red ? color.blueComponent : color.redComponent
        XCTAssertGreaterThan(dominant, opposite + 0.03, file: file, line: line)
        XCTAssertGreaterThan(color.alphaComponent, 0.95, file: file, line: line)
    }

    private func assertBlack(_ color: NSColor, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(max(color.redComponent, color.greenComponent, color.blueComponent), 0.025,
                          file: file, line: line)
        XCTAssertGreaterThan(color.alphaComponent, 0.95, file: file, line: line)
    }
}
