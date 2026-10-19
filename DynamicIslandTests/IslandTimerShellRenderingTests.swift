import AppKit
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandTimerShellRenderingTests: XCTestCase {
    func testMinimalLeafStaysOutsideCameraAndSameActivityCanGrowAndExpand() async throws {
        let model = IslandViewModel.preview()
        model.setCompactPanelSize(CGSize(width: 270, height: 32))
        let runtime = IslandActivityRuntime(viewModel: model)
        defer { runtime.shutdownPlugins() }
        let minimal: IslandNode = .icon(.init("timer"))
        var activity = IslandActivity(
            id: "test.timer.presentation", source: .init(kind: .external, identifier: "test.timer"),
            priority: .normal, lifecycle: .init(policy: .persistent),
            presentation: .init(title: "Focus", minimal: minimal, expanded: .vStack(.init([
                .text(.init("Focus 14:58", color: .accent)), .progress(.init(0.25))
            ]))), createdAt: Date()
        )
        try runtime.manager.publish(activity)
        // The preview runtime already presents its Music Activity. A normal
        // source respects Host debounce/minimum dwell before preempting it;
        // publishing is admission, not a promise that it is current yet.
        for _ in 0..<200 {
            if runtime.manager.currentSnapshot?.activity.id == activity.id,
               runtime.manager.currentSnapshot?.activity.source == activity.source { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = try XCTUnwrap(runtime.manager.currentSnapshot)
        XCTAssertEqual(snapshot.activity.id, activity.id)
        XCTAssertEqual(snapshot.activity.source, activity.source)
        XCTAssertEqual(snapshot.activity.presentation.effectiveCollapsedMode, .minimal)
        let size = IslandPanelGeometry.expandedSize
        let hostingView = NSHostingView(rootView: IslandView(viewModel: model, activityRuntime: runtime)
            .environment(\.colorScheme, .dark))
        hostingView.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = hostingView
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(500))

        let bitmap = try capture(hostingView, canvasSize: size)
        let minimalPNG = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: minimalPNG, uniformTypeIdentifier: "public.png")
        attachment.name = "T11-minimal-camera-wing"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Check painted foreground and camera clearance, independently of an
        // SF Symbol's monochrome/colored NSHostingView snapshot rendering.
        let foregroundPixels = (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).compactMap { x -> Int? in
                guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.8,
                      max(color.redComponent, color.greenComponent, color.blueComponent) > 0.3 else { return nil }
                return x
            }
        }
        XCTAssertGreaterThan(foregroundPixels.count, 10, "The minimal glyph must actually be painted.")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(foregroundPixels.min()), 260 + 135 + 8,
                                   "A minimal leaf must remain to the right of the reserved camera and inset.")

        activity.presentation.compact = .hStack(.init([
            minimal, .spacer(.init()), .text(.init("Focus", color: .accent))
        ]))
        try runtime.manager.update(activity)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(runtime.manager.currentSnapshot?.instanceToken, snapshot.instanceToken)
        XCTAssertEqual(runtime.manager.currentSnapshot?.activity.createdAt, snapshot.activity.createdAt)
        XCTAssertEqual(runtime.manager.currentSnapshot?.activity.presentation.effectiveCollapsedMode, .compact)
        let compact = try capture(hostingView, canvasSize: size)
        XCTAssertNotEqual(bitmap.representation(using: .png, properties: [:]),
                          compact.representation(using: .png, properties: [:]))

        model.setHovering(true)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.presentationState, .expanded)
        XCTAssertEqual(runtime.manager.currentSnapshot?.instanceToken, snapshot.instanceToken)
        let expanded = try capture(hostingView, canvasSize: size)
        XCTAssertNotEqual(compact.representation(using: .png, properties: [:]),
                          expanded.representation(using: .png, properties: [:]))
        // This test verifies pixels and instance continuity. A live countdown
        // and uninterrupted animation are accepted separately on the real UI.
    }

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
            (.countdown, IslandVisualStyle.expandedTimerHeight),
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
        let bitmap = try capture(hostingView, canvasSize: canvasSize)
        // The center column is well away from the rounded corners. The shell is
        // opaque black while everything beyond its lower edge is transparent.
        let centerX = bitmap.pixelsWide / 2
        return (0..<bitmap.pixelsHigh).filter { y in
            (bitmap.colorAt(x: centerX, y: y)?.alphaComponent ?? 0) > 0.95
        }.count
    }

    private func capture<Content: View>(
        _ hostingView: NSHostingView<Content>,
        canvasSize: CGSize
    ) throws -> NSBitmapImageRep {
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
        return bitmap
    }

    private enum RenderingError: Error {
        case bitmapCreationFailed
    }
}
