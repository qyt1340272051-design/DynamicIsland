import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandQuitCancellationTests: XCTestCase {
    func testCancelledTerminationRestoresRenderedIslandHitTestingAndAllowsAnotherQuit() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.model.expandedSurface, .music)
        XCTAssertGreaterThan(try opaqueFraction(in: fixture.view, name: "Before quit"), 0.4)

        try await click(fixture, at: quitButtonCenter)
        try await waitUntil { fixture.termination.requests == 1 }
        XCTAssertLessThan(try opaqueFraction(in: fixture.view, name: "Quit faded"), 0.01,
                          "The actual quit animation must fade the whole hosted island.")

        NotificationCenter.default.post(name: .islandQuitCancelled, object: nil)
        try await settle(fixture.window)
        XCTAssertGreaterThan(try opaqueFraction(in: fixture.view, name: "Cancelled quit restored"), 0.4,
                             "A rejected termination must restore rendered pixels on the same IslandView.")
        try await click(fixture, at: surfaceButtonCenter(index: 1))
        try await waitUntil { fixture.model.expandedSurface == .fileTray }
        try await click(fixture, at: surfaceButtonCenter(index: 0))
        try await waitUntil { fixture.model.expandedSurface == .music }

        try await click(fixture, at: quitButtonCenter)
        try await waitUntil { fixture.termination.requests == 2 }
        XCTAssertEqual(fixture.termination.requests, 2)
    }

    func testCancellationDuringAnimationPreventsLateTerminationAndRestoresNativeClicks() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let started = ContinuousClock.now

        try await click(fixture, at: quitButtonCenter)
        try await Task.sleep(for: .milliseconds(40))
        // This real tab click proves that the first click entered the quit
        // state: the island must reject input until cancellation arrives.
        try await click(fixture, at: surfaceButtonCenter(index: 1))
        XCTAssertEqual(fixture.model.expandedSurface, .music)
        XCTAssertEqual(fixture.termination.requests, 0)
        XCTAssertLessThan(started.duration(to: ContinuousClock.now), animationDuration,
                          "Cancellation must be delivered while the original animation is pending.")

        NotificationCenter.default.post(name: .islandQuitCancelled, object: nil)
        // Wait beyond the complete original animation, including its fade.
        // A detached or uncancelled old task would request termination here.
        try await Task.sleep(for: animationDuration + .milliseconds(200))
        XCTAssertEqual(fixture.termination.requests, 0)
        XCTAssertGreaterThan(try opaqueFraction(in: fixture.view, name: "Mid-animation cancellation restored"), 0.4)
        try await click(fixture, at: surfaceButtonCenter(index: 1))
        try await waitUntil { fixture.model.expandedSurface == .fileTray }
        XCTAssertEqual(fixture.termination.requests, 0)
    }

    private var animationDuration: Duration {
        .nanoseconds(Int64(IslandQuitAnimation.impactHoldNanoseconds
            + IslandQuitAnimation.reboundWaitNanoseconds
            + IslandQuitAnimation.fadeWaitNanoseconds))
    }

    // The production 468 pt content canvas is centered in the 520 pt panel;
    // its switcher has 12 pt padding, 28 pt controls and 8 pt HStack spacing.
    private var contentLeading: CGFloat {
        (IslandPanelGeometry.expandedSize.width - IslandVisualStyle.expandedContentSize.width) / 2
            + IslandVisualStyle.expandedContentPadding
    }

    private var quitButtonCenter: CGPoint {
        CGPoint(x: IslandPanelGeometry.expandedSize.width - contentLeading
                    - IslandVisualStyle.expandedSurfaceSwitcherHeight / 2,
                y: IslandVisualStyle.expandedContentPadding
                    + IslandVisualStyle.expandedSurfaceSwitcherHeight / 2)
    }

    private func surfaceButtonCenter(index: Int) -> CGPoint {
        CGPoint(x: contentLeading + IslandVisualStyle.expandedSurfaceSwitcherHeight / 2
                    + CGFloat(index) * (IslandVisualStyle.expandedSurfaceSwitcherHeight + 8),
                y: IslandVisualStyle.expandedContentPadding
                    + IslandVisualStyle.expandedSurfaceSwitcherHeight / 2)
    }

    private func makeFixture() async throws -> QuitCancellationFixture {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session["CGSSessionScreenIsLocked"] as? Bool == true {
            throw XCTSkip("Real AppKit mouse input requires an unlocked macOS session.")
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("The animated quit path requires Reduce Motion to be off; the test does not change system settings.")
        }
        let model = IslandViewModel.preview()
        model.setHovering(true)
        let runtime = IslandActivityRuntime(viewModel: model)
        let termination = QuitCancellationTerminationWitness()
        let view = NSHostingView(rootView: IslandView(viewModel: model, activityRuntime: runtime,
            requestTermination: { termination.requests += 1 })
            .environment(\.colorScheme, .dark))
        view.frame = CGRect(origin: .zero, size: IslandPanelGeometry.expandedSize)
        let window = NSPanel(contentRect: view.frame,
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        let fixture = QuitCancellationFixture(model: model, runtime: runtime,
            termination: termination, window: window, view: view)
        do {
            try await settle(window)
            try await waitUntil { window.isKeyWindow }
            return fixture
        } catch {
            if !window.isKeyWindow { NativeWindowTestingDiagnostics.keyTimeout(window) }
            fixture.cleanup()
            throw error
        }
    }

    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
    }

    private func click(_ fixture: QuitCancellationFixture, at point: CGPoint) async throws {
        fixture.window.makeKeyAndOrderFront(nil)
        do { try await waitUntil { fixture.window.isKeyWindow } }
        catch {
            NativeWindowTestingDiagnostics.keyTimeout(fixture.window)
            throw error
        }
        let view = fixture.view
        let local = CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
        let location = view.convert(local, to: nil)
        let events = try [NSEvent.EventType.leftMouseDown, .leftMouseUp].map { type in
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(events[1], atStart: true)
        NSApp.sendEvent(events[0])
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
                                    inMode: .eventTracking, dequeue: true) {
            NSApp.sendEvent(up)
        }
    }

    private func opaqueFraction(in view: NSView, name: String) throws -> Double {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        var opaque = 0
        var sampled = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                sampled += 1
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { opaque += 1 }
            }
        }
        return Double(opaque) / Double(sampled)
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("The hosted island did not complete its native control operation.", file: file, line: line)
                throw QuitCancellationTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private struct QuitCancellationFixture {
    let model: IslandViewModel
    let runtime: IslandActivityRuntime
    let termination: QuitCancellationTerminationWitness
    let window: NSPanel
    let view: NSView

    func cleanup() {
        NotificationCenter.default.post(name: .islandQuitCancelled, object: nil)
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        model.setHovering(false)
        runtime.shutdownPlugins()
    }
}

@MainActor
private final class QuitCancellationTerminationWitness {
    var requests = 0
}

private enum QuitCancellationTestError: Error {
    case timedOut
}
