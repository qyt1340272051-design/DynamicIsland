#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class ActivityDebugPanelTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 40_000)

    func testProviderPublishesUpdatesAndEndsThreeSampleKinds() throws {
        for sample in ActivityDebugSample.allCases {
            let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
            let provider = ActivityDebugProvider(manager: manager)

            try provider.publish(sample)
            let original = try XCTUnwrap(manager.current)
            XCTAssertEqual(original.id, sample.activityID)
            XCTAssertEqual(original.source, sample.source)
            XCTAssertEqual(original.lifecycle.state, .presented)

            try provider.update(sample)
            let updated = try XCTUnwrap(manager.current)
            XCTAssertEqual(updated.id, original.id)
            XCTAssertEqual(updated.createdAt, original.createdAt)
            XCTAssertNotEqual(updated.presentation.title, original.presentation.title)

            try provider.end(sample)
            XCTAssertNil(manager.current)
            XCTAssertNil(manager.activity(id: sample.activityID))
        }
    }

    func testHostedViewReflectsPublishUpdateAndEndWithoutRecreatingIt() async throws {
        let manager = ActivityManager(clock: TestActivityClock(start), configuration: .immediate)
        let provider = ActivityDebugProvider(manager: manager)
        let size = CGSize(width: 470, height: 350)
        let hostingView = NSHostingView(rootView: ActivityDebugView(manager: manager, provider: provider))
        hostingView.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        defer { window.close() }

        let empty = try await renderedPNG(hostingView, size: size)
        try provider.publish(.music)
        XCTAssertEqual(manager.current?.presentation.title, "Music · Track 1")
        let published = try await renderedPNG(hostingView, size: size)
        XCTAssertNotEqual(published, empty, "The hosted debug view did not render the published Activity")

        try provider.update(.music)
        XCTAssertEqual(manager.current?.presentation.title, "Music · Track 2")
        let updated = try await renderedPNG(hostingView, size: size)
        XCTAssertNotEqual(updated, published, "The hosted debug view did not render the Activity update")

        try provider.end(.music)
        XCTAssertNil(manager.current)
        let ended = try await renderedPNG(hostingView, size: size)
        XCTAssertNotEqual(ended, updated, "The hosted debug view did not clear the ended Activity")
    }

    private func renderedPNG<Content: View>(
        _ hostingView: NSHostingView<Content>, size: CGSize
    ) async throws -> Data {
        // Allow the existing hosting view to consume the manager's publisher.
        try await Task.sleep(nanoseconds: 100_000_000)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
#endif
