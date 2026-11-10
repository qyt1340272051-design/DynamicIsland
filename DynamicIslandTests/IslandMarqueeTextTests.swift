import AppKit
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandMarqueeTextTests: XCTestCase {
    func testOverflowRejectsInvalidDimensionsAndShortTextHasNoMotion() {
        for (content, viewport): (CGFloat, CGFloat) in [(40, 100), (100, 100), (0, 100),
                                                       (100, 0), (-1, 100), (.infinity, 100), (100, .nan)] {
            XCTAssertEqual(IslandMarqueeMotion.overflow(contentWidth: content, viewportWidth: viewport), 0)
            XCTAssertEqual(IslandMarqueeMotion.offset(for: 3, contentWidth: content, viewportWidth: viewport), 0)
        }
        XCTAssertEqual(IslandMarqueeMotion.overflow(contentWidth: 140, viewportWidth: 100), 40)
    }

    func testPingPongMotionPausesAtBothEdgesAndRepeatsWithoutJumping() {
        let cases: [(TimeInterval, CGFloat)] = [
            (0, 0), (0.5, 0), (1, 0), (2, -20), (3, -40), (4, -60),
            (4.5, -60), (5, -60), (6, -40), (7, -20), (8, 0),
            (8.5, 0), (9, 0), (10, -20), (12, -60), (16, 0)
        ]
        for (elapsed, expected) in cases {
            XCTAssertEqual(IslandMarqueeMotion.offset(for: elapsed, contentWidth: 100, viewportWidth: 40,
                                                       pointsPerSecond: 20, pause: 1), expected, accuracy: 0.0001)
        }
    }

    func testMotionIsAlwaysClampedAndInvalidTimingCannotMoveTheText() {
        for elapsed in stride(from: 0.0, through: 60.0, by: 0.013) {
            let offset = IslandMarqueeMotion.offset(for: elapsed, contentWidth: 123, viewportWidth: 100)
            XCTAssertLessThanOrEqual(offset, 0)
            XCTAssertGreaterThanOrEqual(offset, -23)
        }
        for elapsed in [-1, Double.nan, Double.infinity] {
            XCTAssertEqual(IslandMarqueeMotion.offset(for: elapsed, contentWidth: 140, viewportWidth: 100), 0)
        }
        for speed in [CGFloat(0), -1, .nan, .infinity] {
            XCTAssertEqual(IslandMarqueeMotion.offset(for: 2, contentWidth: 140, viewportWidth: 100,
                                                       pointsPerSecond: speed), 0)
        }
        XCTAssertEqual(IslandMarqueeMotion.offset(for: 2, contentWidth: 140, viewportWidth: 100, pause: .nan), 0)
    }

    func testTimelineAdmissionRequiresVisibleOverflowAndHonorsReduceMotion() {
        XCTAssertTrue(IslandMarqueeMotion.shouldAnimate(contentWidth: 140, viewportWidth: 100,
                                                       isVisible: true, reduceMotion: false))
        XCTAssertFalse(IslandMarqueeMotion.shouldAnimate(contentWidth: 140, viewportWidth: 100,
                                                        isVisible: false, reduceMotion: false))
        XCTAssertFalse(IslandMarqueeMotion.shouldAnimate(contentWidth: 140, viewportWidth: 100,
                                                        isVisible: true, reduceMotion: true))
        XCTAssertFalse(IslandMarqueeMotion.shouldAnimate(contentWidth: 40, viewportWidth: 100,
                                                        isVisible: true, reduceMotion: false))
        XCTAssertFalse(IslandMarqueeMotion.shouldAnimate(contentWidth: 100.25, viewportWidth: 100,
                                                        isVisible: true, reduceMotion: false))
        XCTAssertEqual(IslandMarqueeMotion.offset(for: 1.5, contentWidth: 300, viewportWidth: 100,
                                                   pointsPerSecond: 24), -12)
        XCTAssertEqual(IslandMarqueeMotion.offset(for: 1.5, contentWidth: 300, viewportWidth: 100,
                                                   pointsPerSecond: 48), -24)
    }

    func testLongTextOverlayCannotDrawOutsideItsFixedViewport() throws {
        let content = IslandMarqueeText(content: String(repeating: "Long music title ", count: 10),
                                        font: .system(size: 14), tint: .white, isVisible: false)
            .frame(width: 100, height: 24)
            .padding(.horizontal, 20)
            .background(.black)
        let bitmap = try render(content, size: CGSize(width: 140, height: 24))
        XCTAssertGreaterThan(brightPixels(bitmap, columns: 20..<120), 20)
        XCTAssertEqual(brightPixels(bitmap, columns: 0..<19), 0)
        XCTAssertEqual(brightPixels(bitmap, columns: 121..<140), 0)
    }

    func testShortTextRetainsNativeFontAndLeadingAlignment() throws {
        let size = CGSize(width: 140, height: 24)
        let marquee = IslandMarqueeText(content: "Short", font: .system(size: 14), tint: .white, isVisible: true)
            .frame(width: 140, height: 24, alignment: .leading)
            .background(.black)
        let reference = Text("Short").font(.system(size: 14)).foregroundStyle(.white)
            .lineLimit(1).frame(width: 140, height: 24, alignment: .leading).background(.black)
        let actual = try render(marquee, size: size)
        let expected = try render(reference, size: size)
        XCTAssertGreaterThan(brightPixels(actual, columns: 0..<55), 20)
        XCTAssertEqual(brightPixels(actual, columns: 60..<140), 0)
        XCTAssertEqual(try XCTUnwrap(actual.representation(using: .png, properties: [:])),
                       try XCTUnwrap(expected.representation(using: .png, properties: [:])),
                       "A non-overflowing line must keep native text size, baseline and leading placement.")
    }

    func testShortLabelKeepsIntrinsicWidthInsideTimelineRows() {
        let native = NSHostingView(rootView: Text("00:12").font(.system(size: 14)).lineLimit(1))
        let marquee = NSHostingView(rootView: IslandMarqueeText(content: "00:12", font: .system(size: 14),
                                                              tint: .white, isVisible: true))
        native.layoutSubtreeIfNeeded()
        marquee.layoutSubtreeIfNeeded()
        XCTAssertEqual(marquee.fittingSize.width, native.fittingSize.width, accuracy: 0.5)
        XCTAssertEqual(marquee.fittingSize.height, native.fittingSize.height, accuracy: 0.5)
        XCTAssertLessThan(marquee.fittingSize.width, 60,
                          "Short time labels must not grow into the slider's flexible space.")
    }

    func testShortTextRemainsStableAcrossTimeWithoutAnAnimationTimeline() async throws {
        let hosting = NSHostingView(rootView: IslandMarqueeText(content: "Short", font: .system(size: 14),
                                                              tint: .white, isVisible: true)
            .frame(width: 140, height: 24, alignment: .leading).background(.black))
        hosting.frame = CGRect(x: 0, y: 0, width: 140, height: 24)
        let window = makeWindow(hosting)
        defer { window.close() }
        let first = try capture(hosting)
        try await Task.sleep(for: .milliseconds(100))
        let second = try capture(hosting)
        XCTAssertEqual(try XCTUnwrap(first.representation(using: .png, properties: [:])),
                       try XCTUnwrap(second.representation(using: .png, properties: [:])))
    }

    func testVisibleOverflowingLineActuallyMovesWithinClippedViewport() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("Visible motion honors the user's Reduce Motion setting.")
        }
        let hosting = NSHostingView(rootView: IslandMarqueeText(
            content: "ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 A long music title",
            font: .system(size: 14), tint: .white, isVisible: true)
            .frame(width: 100, height: 24, alignment: .leading)
            .padding(.horizontal, 20).background(.black))
        hosting.frame = CGRect(x: 0, y: 0, width: 140, height: 24)
        let window = makeWindow(hosting)
        defer { window.close() }
        window.orderFront(nil)
        // Let the viewport and unrestricted overlay report their geometry;
        // the first capture remains inside the initial one-second rest.
        try await Task.sleep(for: .milliseconds(100))
        let first = try capture(hosting)
        try await Task.sleep(for: .milliseconds(1750))
        let moved = try capture(hosting)
        XCTAssertGreaterThan(brightPixels(first, columns: 20..<120), 20)
        XCTAssertGreaterThan(brightPixels(moved, columns: 20..<120), 20)
        XCTAssertNotEqual(try XCTUnwrap(first.representation(using: .png, properties: [:])),
                          try XCTUnwrap(moved.representation(using: .png, properties: [:])),
                          "A mounted visible overflowing line must move after its initial endpoint pause.")
        XCTAssertEqual(brightPixels(moved, columns: 0..<19), 0)
        XCTAssertEqual(brightPixels(moved, columns: 121..<140), 0)
        for (name, bitmap) in [("start", first), ("moving", moved)] {
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = "Marquee-visible-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func render<Content: View>(_ view: Content, size: CGSize) throws -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = makeWindow(hosting)
        defer { window.close() }
        return try capture(hosting)
    }

    private func makeWindow<Content: View>(_ hosting: NSHostingView<Content>) -> NSWindow {
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.isOpaque = true
        window.contentView = hosting
        return window
    }

    private func capture<Content: View>(_ hosting: NSHostingView<Content>) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(hosting.bounds.width), pixelsHigh: Int(hosting.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        bitmap.size = hosting.bounds.size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    private func brightPixels(_ bitmap: NSBitmapImageRep, columns: Range<Int>) -> Int {
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in columns {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.5 && max(color.redComponent, max(color.greenComponent, color.blueComponent)) > 0.4 {
                    count += 1
                }
            }
        }
        return count
    }
}
