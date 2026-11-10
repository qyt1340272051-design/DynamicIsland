import AppKit
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandCompactMusicRefreshTests: XCTestCase {
    func testAutomaticCompactPollingUpdatesWithoutHoverOrManualRefresh() async throws {
        let red = try artwork(.red)
        let blue = try artwork(.blue)
        let fixture = CompactMusicWindowFixture(pollIntervalNanoseconds: 1_500_000_000)
        defer { fixture.close() }
        print("COMPACT_AUTOMATIC_APP_ACTIVE=\(NSApp.isActive)")
        XCTAssertFalse(fixture.panel.isKeyWindow)
        await fixture.service.setInfo(track("Automatic first", artwork: red, duration: 0))
        try await fixture.waitUntil(timeout: 2.5) { fixture.model.nowPlaying.title == "Automatic first" }
        try await fixture.waitForTitle("Automatic first")
        assertArtwork(try await fixture.capture(), expected: .red, context: "automatic-first")

        let changedAt = Date()
        await fixture.service.setInfo(track("Automatic second", artwork: blue, duration: 0))
        try await fixture.waitUntil(timeout: 2.5) { fixture.model.nowPlaying.title == "Automatic second" }
        let appliedLatency = Date().timeIntervalSince(changedAt)
        XCTAssertLessThan(appliedLatency, 2.5)
        try await fixture.waitForTitle("Automatic second")
        assertArtwork(try await fixture.capture(), expected: .blue, context: "automatic-second-no-refresh")

        // Also change only the resource bytes, with no progress/title trigger.
        await fixture.service.setInfo(track("Automatic second", artwork: red, duration: 0))
        try await fixture.waitUntil(timeout: 2.5) { fixture.model.nowPlaying.artworkData == red }
        assertArtwork(try await fixture.capture(), expected: .red, context: "automatic-art-only-no-refresh")
        XCTAssertFalse(fixture.model.isPointerInside)
        XCTAssertFalse(fixture.model.isHovering)
        XCTAssertEqual(fixture.model.presentationState, .compact)
        print("COMPACT_AUTOMATIC_TRACK_APPLY_MS=\(Int(appliedLatency * 1_000))")
    }

    func testSameCompactIslandUpdatesTrackArtworkWithoutHovering() async throws {
        let red = try artwork(.red)
        let blue = try artwork(.blue)
        let fixture = CompactMusicWindowFixture()
        defer { fixture.close() }
        XCTAssertFalse(fixture.panel.isKeyWindow, "The real music panel is nonactivating.")

        await fixture.service.setInfo(track("First", artwork: red))
        await fixture.model.refreshNowPlaying()
        try await fixture.waitForTitle("First")
        let initialToken = fixture.runtime.manager.currentSnapshot?.instanceToken
        let first = try await fixture.capture()
        assertArtwork(first, expected: .red, context: "first")

        await fixture.service.setInfo(track("Second", artwork: blue))
        await fixture.model.refreshNowPlaying()
        try await fixture.waitForTitle("Second")
        let second = try await fixture.capture()
        assertArtwork(second, expected: .blue, context: "second-without-hover")
        XCTAssertEqual(fixture.runtime.manager.currentSnapshot?.instanceToken, initialToken,
                       "Track updates must repaint the existing Activity instance.")
        XCTAssertFalse(fixture.model.isPointerInside)
        XCTAssertFalse(fixture.model.isHovering)
        XCTAssertEqual(fixture.model.presentationState, .compact)

        await fixture.service.setInfo(track("Second", artwork: blue, playing: false))
        await fixture.model.refreshNowPlaying()
        try await fixture.waitUntil { !fixture.runtime.isCompactActivityVisible }
        let paused = try await fixture.capture()
        XCTAssertLessThan(coloredPixels(paused, color: .red) + coloredPixels(paused, color: .blue), 30,
                          "A paused music Activity should hide its compact artwork.")
        await fixture.service.setInfo(track("Second", artwork: blue))
        await fixture.model.refreshNowPlaying()
        try await fixture.waitUntil { fixture.runtime.isCompactActivityVisible }
        assertArtwork(try await fixture.capture(), expected: .blue, context: "resumed-without-hover")
        XCTAssertEqual(fixture.model.presentationState, .compact)
    }

    func testLateAndReplacedArtworkRepaintsCompactIslandWithUnchangedMetadata() async throws {
        let red = try artwork(.red)
        let blue = try artwork(.blue)
        let fixture = CompactMusicWindowFixture()
        defer { fixture.close() }
        // A zero-duration live source has no changing progress value. This
        // isolates artwork invalidation from incidental clock/presentation ticks.
        await fixture.service.setInfo(track("Live", artwork: nil, duration: 0))
        await fixture.model.refreshNowPlaying()
        try await fixture.waitForTitle("Live")
        let token = fixture.runtime.manager.currentSnapshot?.instanceToken
        let missing = try await fixture.capture()
        XCTAssertEqual(coloredPixels(missing, color: .red) + coloredPixels(missing, color: .blue), 0)

        await fixture.service.setInfo(track("Live", artwork: red, duration: 0))
        await fixture.model.refreshNowPlaying()
        assertArtwork(try await fixture.capture(), expected: .red, context: "late-cover-without-hover")

        await fixture.service.setInfo(track("Live", artwork: blue, duration: 0))
        await fixture.model.refreshNowPlaying()
        assertArtwork(try await fixture.capture(), expected: .blue, context: "replacement-cover-without-hover")
        XCTAssertEqual(fixture.runtime.manager.currentSnapshot?.instanceToken, token)

        await fixture.service.setInfo(track("Next live", artwork: nil, duration: 0))
        await fixture.model.refreshNowPlaying()
        try await fixture.waitForTitle("Next live")
        let nextMissing = try await fixture.capture()
        XCTAssertLessThan(coloredPixels(nextMissing, color: .red) + coloredPixels(nextMissing, color: .blue), 30,
                          "Changing songs without new artwork must not show the old cover.")
        await fixture.service.setInfo(track("Next live", artwork: red, duration: 0))
        await fixture.model.refreshNowPlaying()
        assertArtwork(try await fixture.capture(), expected: .red, context: "next-late-cover-without-hover")
        XCTAssertFalse(fixture.model.isPointerInside)
        XCTAssertFalse(fixture.model.isHovering)
        XCTAssertEqual(fixture.model.presentationState, .compact)
    }

    private func track(_ title: String, artwork: Data?, playing: Bool = true, duration: TimeInterval = 120) -> NowPlayingInfo {
        .init(isPlaying: playing, title: title, artist: "Artist", album: "Album",
              duration: duration, position: 0, trackIdentifier: title, artworkData: artwork)
    }

    private func artwork(_ color: NSColor) throws -> Data {
        let image = NSImage(size: CGSize(width: 48, height: 48), flipped: false) { rectangle in
            color.setFill()
            NSBezierPath(rect: rectangle).fill()
            return true
        }
        return try XCTUnwrap(image.tiffRepresentation)
    }

    private func assertArtwork(_ bitmap: NSBitmapImageRep, expected: CoverColor, context: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let expectedPixels = coloredPixels(bitmap, color: expected)
        let stalePixels = coloredPixels(bitmap, color: expected == .red ? .blue : .red)
        XCTAssertGreaterThan(expectedPixels, 200,
                             "\(context): compact thumbnail did not repaint without a hover/layout event.", file: file, line: line)
        XCTAssertLessThan(stalePixels, 30, "\(context): stale artwork remains visible.", file: file, line: line)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = "Compact-music-\(context)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private enum CoverColor { case red, blue }

    private func coloredPixels(_ bitmap: NSBitmapImageRep, color: CoverColor) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), pixel.alphaComponent > 0.5 else { continue }
                if color == .red && pixel.redComponent > 0.7 && pixel.greenComponent < 0.3 && pixel.blueComponent < 0.3 { count += 1 }
                if color == .blue && pixel.blueComponent > 0.7 && pixel.greenComponent < 0.3 && pixel.redComponent < 0.3 { count += 1 }
            }
        }
        return count
    }
}

@MainActor
private final class CompactMusicWindowFixture {
    let service: MusicActivityTestService
    let model: IslandViewModel
    let runtime: IslandActivityRuntime
    let hosting: NSHostingView<IslandView>
    let panel: NSPanel

    init(pollIntervalNanoseconds: UInt64? = nil) {
        service = MusicActivityTestService(info: .empty)
        if let pollIntervalNanoseconds {
            model = IslandViewModel(volumeService: MusicActivityTestVolume(), fileTrayService: MusicActivityTestTray(),
                sharingService: MusicActivityTestSharing(), musicService: service,
                hapticFeedbackService: MusicActivityTestHaptic(), nowPlayingPollIntervalNanoseconds: pollIntervalNanoseconds)
        } else { model = makeMusicActivityTestModel(music: service) }
        model.setScreenEnvironment(ScreenEnvironment(displayID: 1, name: "Compact music fixture",
            frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
            visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 924), safeAreaInsets: .init(top: 32),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 924, width: 645.5, height: 32),
            auxiliaryTopRightArea: CGRect(x: 824.5, y: 924, width: 645.5, height: 32),
            backingScaleFactor: 2, isBuiltIn: true))
        model.setHovering(false)
        runtime = IslandActivityRuntime(viewModel: model)
        hosting = NSHostingView(rootView: IslandView(viewModel: model, activityRuntime: runtime))
        hosting.frame = CGRect(origin: .zero, size: model.displayLayout.panelSize)
        panel = NSPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = hosting
        panel.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
    }

    func close() { panel.close(); runtime.shutdownPlugins() }

    func waitForTitle(_ title: String) async throws {
        try await waitUntil { self.runtime.manager.currentSnapshot?.activity.presentation.title == title }
    }

    func waitUntil(timeout: TimeInterval = 1, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CompactMusicFixtureError.timedOut
    }

    func capture() async throws -> NSBitmapImageRep {
        // Let ordinary SwiftUI invalidation repaint the same visible panel;
        // do not hover, change rootView, or force a separate layout transition.
        try await Task.sleep(nanoseconds: 180_000_000)
        let size = hosting.bounds.size
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width)), pixelsHigh: Int(ceil(size.height)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }
}

private enum CompactMusicFixtureError: Error { case timedOut }
