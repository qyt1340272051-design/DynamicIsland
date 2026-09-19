import AppKit
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandTimerShellRenderingTests: XCTestCase {
    func testExpandedTimerModeSwitchUpdatesRenderedOuterShellHeight() async throws {
        let model = IslandViewModel.preview()
        model.setHovering(true)
        model.selectExpandedSurface(.tools)

        let size = IslandPanelGeometry.expandedSize
        let hostingView = NSHostingView(
            rootView: IslandView(viewModel: model)
                .environment(\.colorScheme, .dark)
        )
        hostingView.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor.clear
        window.isOpaque = false
        window.contentView = hostingView
        defer { window.close() }

        // Keep the same hosted IslandView alive: a fresh view for each mode would
        // miss a stale shell after an in-place picker selection.
        for (mode, expectedHeight) in [
            (IslandTimerToolMode.stopwatch, IslandVisualStyle.expandedCompactContentHeight),
            (.pomodoro, IslandVisualStyle.expandedShellSize.height),
            (.countdown, IslandVisualStyle.expandedShellSize.height),
            (.stopwatch, IslandVisualStyle.expandedCompactContentHeight)
        ] {
            model.timerTools.selectedMode = mode
            try await Task.sleep(nanoseconds: 500_000_000)

            let height = try renderedOpaqueShellHeight(in: hostingView, canvasSize: size)
            XCTAssertLessThanOrEqual(
                abs(height - Int(expectedHeight)),
                3,
                "The outer shell did not follow the \(mode.title) picker selection."
            )
        }
    }

    private func renderedOpaqueShellHeight<Content: View>(
        in hostingView: NSHostingView<Content>,
        canvasSize: CGSize
    ) throws -> Int {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvasSize.width),
            pixelsHigh: Int(canvasSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw RenderingError.bitmapCreationFailed
        }

        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        bitmap.size = canvasSize
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        // The center column is well away from the rounded corners. The shell is
        // opaque black while everything beyond its lower edge is transparent.
        let centerX = bitmap.pixelsWide / 2
        return (0..<bitmap.pixelsHigh).filter { y in
            (bitmap.colorAt(x: centerX, y: y)?.alphaComponent ?? 0) > 0.95
        }.count
    }

    private enum RenderingError: Error {
        case bitmapCreationFailed
    }
}
