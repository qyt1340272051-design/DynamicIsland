import AppKit
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandCountdownCompactLayoutTests: XCTestCase {
    func testCompactCountdownGlyphsRemainOutsidePhysicalNotchAtEveryTimeWidth() throws {
        let baseSize = CGSize(width: 210, height: 32)
        let shellSize = IslandVisualStyle.compactShellSize(
            baseSize: baseSize, hasCompactActivity: true, hasActiveTimer: true
        )
        // The shared 150 pt timer expansion leaves camera clearance for
        // eight-character values after the renderer's horizontal padding.
        XCTAssertEqual(shellSize, CGSize(width: 360, height: 32))
        XCTAssertEqual(IslandRenderer.contentSize(for: .compact, shellSize: shellSize),
                       CGSize(width: 344, height: 32))
        let clock = IslandCountdownDisplayClock()
        defer { clock.shutdown() }
        let countdown = IslandNode.Countdown(
            id: "focus", generation: "12345678-1234-1234-1234-123456789abc", style: .time, color: .primary
        )
        let tree: IslandNode = .hStack(.init([
            .icon(.init("timer")), .spacer(.init()), .countdown(countdown)
        ]))
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(tree, for: .compact))
        let notchStart = Int((shellSize.width - baseSize.width) / 2)
        let notchEnd = notchStart + Int(baseSize.width)

        for text in ["00:15", "59:59", "1:00:00", "24:00:00"] {
            let renderer = IslandRenderer(
                presentation: .init(title: "Countdown", compact: tree),
                mode: .compact, shellSize: shellSize,
                countdownResolver: { reference in
                    XCTAssertEqual(reference, countdown)
                    return .init(text: text, progress: 0.5, requiresTick: false)
                },
                isVisible: true, displayClock: clock
            )
            let hostingView = NSHostingView(rootView: renderer
                .frame(width: shellSize.width, height: shellSize.height)
                .background(Color.black)
                .environment(\.colorScheme, .dark))
            hostingView.frame = CGRect(origin: .zero, size: shellSize)
            let window = NSWindow(contentRect: hostingView.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            window.isOpaque = true
            window.contentView = hostingView
            defer { window.contentView = nil; window.close() }

            let bitmap = try capture(hostingView, size: shellSize)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "Compact countdown \(text) original 360x32"
            attachment.lifetime = .keepAlways
            add(attachment)

            var leftGlyphPixels = 0
            var centerGlyphPixels = 0
            var rightGlyphPixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          pixel.alphaComponent > 0.1,
                          max(pixel.redComponent, max(pixel.greenComponent, pixel.blueComponent)) > 0.01 else { continue }
                    if x < notchStart { leftGlyphPixels += 1 }
                    else if x < notchEnd { centerGlyphPixels += 1 }
                    else { rightGlyphPixels += 1 }
                }
            }
            XCTAssertGreaterThan(leftGlyphPixels, 0, "The timer icon must be visible for \(text).")
            XCTAssertGreaterThan(rightGlyphPixels, 0, "The time must be visible for \(text).")
            XCTAssertEqual(centerGlyphPixels, 0,
                           "\(text) paints \(centerGlyphPixels) glyph pixels inside the physical 210pt notch.")
            XCTAssertEqual(clock.consumerCount, 0)
            XCTAssertEqual(clock.timerCount, 0)
        }
    }

    private func capture(_ view: NSView, size: CGSize) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
}
