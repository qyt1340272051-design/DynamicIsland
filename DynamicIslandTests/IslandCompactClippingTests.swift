import AppKit
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandCompactClippingTests: XCTestCase {
    func testAcceptedAsymmetricMinimalTextKeepsItsCompleteNativeGlyphs() async throws {
        let model = IslandViewModel.preview()
        let baseSize = CGSize(width: 260, height: 32)
        model.setCompactPanelSize(baseSize)
        let runtime = IslandActivityRuntime(viewModel: model)
        defer { runtime.shutdownPlugins() }

        // This fits the right side of the 520 pt panel while extending beyond
        // the former, centered 428 pt expanded-content clipping rectangle.
        let presentation = ActivityPresentation(
            title: "Wide minimal leaf", minimal: .text(.init(String(repeating: "W", count: 10)))
        )
        let layout = IslandCompactLayout.activity(baseSize: baseSize, presentation: presentation)
        XCTAssertTrue(layout.usesMinimalPresentation)
        XCTAssertNil(layout.fallbackMinimalNode)
        XCTAssertEqual(layout.leadingWidth, 0)
        XCTAssertLessThanOrEqual(layout.size.width, IslandVisualStyle.expandedShellSize.width)
        let canvasSize = IslandPanelGeometry.expandedSize
        let cameraRight = canvasSize.width / 2 + baseSize.width / 2
        XCTAssertLessThanOrEqual(cameraRight + layout.trailingWidth, canvasSize.width)

        let activity = IslandActivity(
            id: "test.compact.asymmetric.clipping",
            source: .init(kind: .external, identifier: "test.compact.clipping"),
            priority: .normal, lifecycle: .init(policy: .persistent),
            presentation: presentation, createdAt: Date()
        )
        try runtime.manager.publish(activity)
        for _ in 0..<200 {
            if runtime.manager.currentSnapshot?.activity.id == activity.id { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(runtime.manager.currentSnapshot?.activity.id, activity.id)

        let island = NSHostingView(rootView: IslandView(viewModel: model, activityRuntime: runtime)
            .environment(\.colorScheme, .dark)
            .transaction { $0.disablesAnimations = true })
        island.frame = CGRect(origin: .zero, size: canvasSize)
        let islandWindow = makeWindow(island)
        defer { islandWindow.close() }

        let regionSize = CGSize(width: layout.trailingWidth, height: layout.size.height)
        let reference = NSHostingView(rootView: IslandRenderer(
            presentation: presentation, mode: .minimal, shellSize: regionSize
        )
            .frame(width: regionSize.width, height: regionSize.height)
            .background(.black)
            .environment(\.colorScheme, .dark)
            .transaction { $0.disablesAnimations = true })
        reference.frame = CGRect(origin: .zero, size: regionSize)
        let referenceWindow = makeWindow(reference)
        defer { referenceWindow.close() }
        try await Task.sleep(for: .milliseconds(200))

        let actualPixels = try foreground(in: capture(island, size: canvasSize))
        let referencePixels = try foreground(in: capture(reference, size: regionSize))
        let formerClipRight = (canvasSize.width + IslandVisualStyle.expandedContentSize.width) / 2
        XCTAssertGreaterThan(cameraRight + referencePixels.bounds.maxX, formerClipRight + 15,
                             "The native reference must cross the old compact-content clip.")
        XCTAssertEqual(actualPixels.bounds.width, referencePixels.bounds.width, accuracy: 1,
                       "The complete measured leaf must survive the actual Host's masks and frames.")
        XCTAssertGreaterThanOrEqual(actualPixels.coverage, referencePixels.coverage * 0.95,
                                    "The Host must retain the full glyph coverage of a direct native renderer.")
    }

    private func makeWindow<Content: View>(_ hostingView: NSHostingView<Content>) -> NSWindow {
        let window = NSWindow(contentRect: hostingView.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = hostingView
        return window
    }

    private func capture<Content: View>(_ hostingView: NSHostingView<Content>,
                                      size: CGSize) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return bitmap
    }

    private func foreground(in bitmap: NSBitmapImageRep) throws -> (bounds: CGRect, coverage: Double) {
        var bounds = CGRect.null
        var coverage = 0.0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                let brightness = max(color.redComponent, color.greenComponent, color.blueComponent)
                    * color.alphaComponent
                guard brightness > 0.1 else { continue }
                coverage += Double(brightness)
                bounds = bounds.union(CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1))
            }
        }
        XCTAssertFalse(bounds.isNull, "The comparison requires painted text in both renderings.")
        return (bounds, coverage)
    }
}
