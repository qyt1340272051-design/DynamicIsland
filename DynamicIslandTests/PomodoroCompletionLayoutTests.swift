import AppKit
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class PomodoroCompletionLayoutTests: XCTestCase {
    func testCompletionCompactGlyphsStayInBothWingsOutsidePhysicalNotch() throws {
        let compact: IslandNode = .hStack(.init([
            .icon(.init("checkmark.circle.fill")),
            .spacer(.init()),
            .text(.init("完成"))
        ]))
        let presentation = ActivityPresentation(
            title: "专注完成", subtitle: "本轮专注已结束", symbolName: "checkmark.circle.fill",
            compact: compact
        )
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(compact, for: .compact))
        XCTAssertEqual(IslandRenderer.resolvedNode(in: presentation, for: .compact), compact)

        for baseSize in [CGSize(width: 312, height: 56), CGSize(width: 210, height: 32)] {
            let shellSize = IslandVisualStyle.compactShellSize(
                baseSize: baseSize, hasCompactActivity: true
            )
            XCTAssertEqual(shellSize.width, baseSize.width + 72)
            XCTAssertEqual(shellSize.height, baseSize.height)
            let bitmap = try render(
                presentation, shellSize: shellSize,
                name: "completion-wings-\(Int(shellSize.width))x\(Int(shellSize.height))"
            )
            let pixels = glyphPixels(in: bitmap, shellSize: shellSize, notchWidth: baseSize.width)
            XCTAssertGreaterThan(pixels.left, 8, "The completion symbol must remain visible.")
            XCTAssertGreaterThan(pixels.right, 8, "The completion text must remain visible.")
            XCTAssertEqual(pixels.center, 0,
                           "Completion paints \(pixels.center) glyph pixels behind the \(Int(baseSize.width))pt camera notch.")
        }
    }

    func testLegacyCenteredSummaryPaintsBehindActualCameraNotch() throws {
        // Positive control: the same title without an authored compact layout
        // fits the renderer but paints entirely inside the physical notch.
        let presentation = ActivityPresentation(
            title: "专注完成", subtitle: "本轮专注已结束", symbolName: "checkmark.circle.fill"
        )
        let baseSize = CGSize(width: 312, height: 56)
        let shellSize = IslandVisualStyle.compactShellSize(
            baseSize: baseSize, hasCompactActivity: true
        )
        XCTAssertEqual(shellSize, CGSize(width: 384, height: 56))
        XCTAssertEqual(IslandRenderer.resolvedNode(in: presentation, for: .compact), .hStack(.init([
            .icon(.init("checkmark.circle.fill")), .text(.init("专注完成"))
        ])))
        let bitmap = try render(presentation, shellSize: shellSize,
                                name: "legacy-centered-summary-384x56")
        let pixels = glyphPixels(in: bitmap, shellSize: shellSize, notchWidth: baseSize.width)
        XCTAssertGreaterThan(pixels.center, 20,
                             "The control must detect actual rendered glyphs in the camera region.")
        XCTAssertEqual(pixels.left, 0)
        XCTAssertEqual(pixels.right, 0)
    }

    private func render(_ presentation: ActivityPresentation, shellSize: CGSize,
                        name: String) throws -> NSBitmapImageRep {
        let hostingView = NSHostingView(rootView: IslandRenderer(
            presentation: presentation, mode: .compact, shellSize: shellSize
        )
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

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(shellSize.width), pixelsHigh: Int(shellSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        if let data = bitmap.bitmapData {
            data.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        bitmap.size = shellSize
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dynamic-island-t35-completion-layout-20261016", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name + " original"
        attachment.lifetime = .keepAlways
        add(attachment)
        return bitmap
    }

    private func glyphPixels(in bitmap: NSBitmapImageRep, shellSize: CGSize,
                             notchWidth: CGFloat) -> (left: Int, center: Int, right: Int) {
        let notchStart = Int((shellSize.width - notchWidth) / 2)
        let notchEnd = notchStart + Int(notchWidth)
        var left = 0, center = 0, right = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.1,
                      max(color.redComponent, max(color.greenComponent, color.blueComponent)) > 0.01
                else { continue }
                if x < notchStart { left += 1 }
                else if x < notchEnd { center += 1 }
                else { right += 1 }
            }
        }
        return (left, center, right)
    }
}
