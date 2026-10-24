import AppKit
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandDisplayNativeControlTests: XCTestCase {
    func testNativeToolButtonDrawsAtFinalPointSizeForBoundsAnchorAndHitRegion() async throws {
        let reference = try await inspectNativeControl(
            environment: environment(width: 1470, height: 956, notchWidth: 179, notchHeight: 32)
        )

        _ = try await inspectNativeControl(
            environment: environment(width: 1280, height: 832, notchWidth: 156, notchHeight: 28),
            reference: reference
        )

        // This third mode is a synthetic geometry regression, not a claim of
        // hardware or native menu-tracking acceptance at this display mode.
        _ = try await inspectNativeControl(
            environment: environment(width: 1710, height: 1112, notchWidth: 208, notchHeight: 37),
            reference: reference
        )

        _ = try await inspectNativeControl(
            environment: environment(width: 2560, height: 1664, notchWidth: 312, notchHeight: 56),
            reference: reference
        )
    }

    private func inspectNativeControl(
        environment: ScreenEnvironment,
        reference: NativeControlMeasurement? = nil
    ) async throws -> NativeControlMeasurement {
        let model = IslandViewModel.preview()
        model.setScreenEnvironment(environment)
        let runtime = IslandActivityRuntime(viewModel: model)
        defer { runtime.shutdownPlugins() }

        let toolID = "display-native-control-tool"
        try runtime.manager.publish(.init(
            id: toolID,
            source: .init(kind: .builtIn, identifier: toolID),
            priority: .background,
            lifecycle: .init(policy: .persistent),
            presentation: .init(
                title: "Native control layout fixture",
                expanded: .text(.init("Controlled layout fixture")),
                showsCompact: false,
                role: .tool
            ),
            createdAt: Date()
        ))
        model.setHovering(true)
        let tool = try XCTUnwrap(runtime.manager.toolSnapshots.first { $0.activity.id == toolID })
        XCTAssertTrue(runtime.selectTool(tool))
        XCTAssertEqual(model.presentationState, .expanded)
        XCTAssertTrue(runtime.currentActivityUsesToolLayout)

        let root = IslandView(viewModel: model, activityRuntime: runtime, requestTermination: {
            XCTFail("Layout inspection must not activate the quit control.")
        })
        .environment(\.colorScheme, .dark)
        .transaction { $0.disablesAnimations = true }
        let hosting = NSHostingView(rootView: root)
        let layout = model.displayLayout
        hosting.frame = CGRect(origin: .zero, size: layout.panelSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        // NSWindow rounds fractional content sizes up to whole points. Keep
        // the hosting viewport at the exact display-layout size in a plain
        // container so that this test measures final points, not window fit.
        let container = NSView(frame: hosting.frame)
        window.contentView = container
        hosting.autoresizingMask = []
        container.addSubview(hosting)
        defer { window.close() }

        let button = try await settledNativeButton(in: hosting)
        XCTAssertTrue(button.window === window)
        XCTAssertFalse(window.isVisible, "The fixture must not present a user-facing window.")
        XCTAssertTrue(button.isEnabled)
        XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
        XCTAssertNotNil(button.target)
        XCTAssertNotNil(button.action)
        let buttonSide = 28 * layout.expandedScale
        XCTAssertEqual(button.layoutScale, layout.expandedScale, accuracy: 0.000_001)
        XCTAssertEqual(button.intrinsicContentSize.width, buttonSide, accuracy: 0.001)
        XCTAssertEqual(button.intrinsicContentSize.height, buttonSide, accuracy: 0.001)
        // AppKit may round the hosted frame to whole layout points. The
        // requested intrinsic size above stays exact, and conversion below
        // must still preserve the resulting native bounds without scaling.
        XCTAssertEqual(button.bounds.width, buttonSide, accuracy: 1)
        XCTAssertEqual(button.bounds.height, buttonSide, accuracy: 1)
        XCTAssertEqual(button.frame.width, buttonSide, accuracy: 1)
        XCTAssertEqual(button.frame.height, buttonSide, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(button.layer).cornerRadius, 14 * layout.expandedScale, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(button.layer).borderWidth, 0.5 * layout.expandedScale, accuracy: 0.001)
        let symbol = try XCTUnwrap(button.image)
        let expectedSymbol = try XCTUnwrap(NSImage(systemSymbolName: "alarm.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12 * layout.expandedScale, weight: .semibold)))
        XCTAssertEqual(symbol.size.width, expectedSymbol.size.width, accuracy: 0.001)
        XCTAssertEqual(symbol.size.height, expectedSymbol.size.height, accuracy: 0.001)
        XCTAssertEqual(button.imageScaling, .scaleNone)

        // Native bounds already use final display points. A whole-island
        // magnification would apply scale twice and fail this conversion check.
        let buttonRect = button.convert(button.bounds, to: hosting)
        let popupAnchor = button.convert(
            NSPoint(x: button.bounds.minX, y: button.bounds.minY - 4 * layout.expandedScale), to: hosting
        )
        let alignmentRect = try XCTUnwrap(button.superview).convert(
            button.alignmentRect(forFrame: button.frame), to: hosting
        )
        XCTAssertEqual(buttonRect.width, button.bounds.width, accuracy: 0.05)
        XCTAssertEqual(buttonRect.height, button.bounds.height, accuracy: 0.05)
        XCTAssertEqual(alignmentRect.width, buttonRect.width, accuracy: 0.05)
        XCTAssertEqual(alignmentRect.height, buttonRect.height, accuracy: 0.05)
        XCTAssertEqual(alignmentRect.minX, buttonRect.minX, accuracy: 0.05)
        XCTAssertEqual(alignmentRect.minY, buttonRect.minY, accuracy: 0.05)
        XCTAssertEqual(popupAnchor.x, buttonRect.minX, accuracy: 0.05)
        let expectedPopupY = button.isFlipped == hosting.isFlipped
            ? buttonRect.minY - 4 * layout.expandedScale
            : buttonRect.maxY + 4 * layout.expandedScale
        XCTAssertEqual(popupAnchor.y, expectedPopupY, accuracy: 0.05)
        let attachment = XCTAttachment(string:
            "scale=\(layout.scale) expandedScale=\(layout.expandedScale) hosting=\(hosting.bounds) native=\(buttonRect) alignment=\(alignmentRect) popupAnchor=\(popupAnchor)")
        attachment.name = "Native-tool-control-scale-\(layout.scale)"
        attachment.lifetime = .keepAlways
        add(attachment)

        let shellSize = layout.scaledExpanded(IslandVisualStyle.expandedShellSize)
        let shellRect = CGRect(
            x: (hosting.bounds.width - shellSize.width) / 2,
            y: hosting.isFlipped ? hosting.bounds.minY : hosting.bounds.maxY - shellSize.height,
            width: shellSize.width,
            height: shellSize.height
        )
        XCTAssertTrue(shellRect.contains(buttonRect),
                      "Native button \(buttonRect) must remain inside the expanded shell \(shellRect).")
        XCTAssertTrue(shellRect.contains(popupAnchor),
                      "The native popup anchor must remain inside the scaled expanded shell.")

        let expectedAlignmentRect: CGRect
        if let reference {
            // Native representables may align their origin to the controlled
            // window's pixel grid. This is only an assertion tolerance; the
            // screen environment's backing scale never sets layout scale.
            // The reference already includes expanded density; the stable
            // panel and cross-screen coordinates still use the base scale.
            let positionAccuracy = max(0.05, 0.5 / window.backingScaleFactor)
            expectedAlignmentRect = CGRect(
                x: reference.alignmentRect.minX * layout.scale,
                y: reference.alignmentRect.minY * layout.scale,
                width: reference.alignmentRect.width * layout.scale,
                height: reference.alignmentRect.height * layout.scale
            )
            XCTAssertEqual(buttonRect.width, reference.buttonRect.width * layout.scale, accuracy: 1)
            XCTAssertEqual(buttonRect.height, reference.buttonRect.height * layout.scale, accuracy: 1)
            XCTAssertEqual(buttonRect.minX, reference.buttonRect.minX * layout.scale, accuracy: positionAccuracy)
            XCTAssertEqual(buttonRect.minY, reference.buttonRect.minY * layout.scale, accuracy: positionAccuracy)
            XCTAssertEqual(alignmentRect.minX, expectedAlignmentRect.minX, accuracy: positionAccuracy)
            XCTAssertEqual(alignmentRect.minY, expectedAlignmentRect.minY, accuracy: positionAccuracy)
        } else {
            XCTAssertEqual(layout.scale, 1, accuracy: 0.000_001)
            expectedAlignmentRect = alignmentRect
        }

        // Derive points from the independent 1x baseline, rather than from the
        // resized button's own conversion, to detect a stale hit region.
        // hitTest receives coordinates in its receiver's superview. No mouse
        // events or actions are sent, and NSMenu.popUp is deliberately not run.
        let parent = try XCTUnwrap(hosting.superview)
        let inset: CGFloat = 4 * layout.expandedScale
        let points = [
            CGPoint(x: expectedAlignmentRect.midX, y: expectedAlignmentRect.midY),
            CGPoint(x: expectedAlignmentRect.minX + inset, y: expectedAlignmentRect.midY),
            CGPoint(x: expectedAlignmentRect.maxX - inset, y: expectedAlignmentRect.midY),
            CGPoint(x: expectedAlignmentRect.midX, y: expectedAlignmentRect.minY + inset),
            CGPoint(x: expectedAlignmentRect.midX, y: expectedAlignmentRect.maxY - inset)
        ]
        for point in points {
            let hit = hosting.hitTest(parent.convert(point, from: hosting))
            XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true,
                          "Expected native button hit at \(point), got \(String(describing: hit)).")
        }

        // This verifies the native control's bounds, popup input anchor and
        // direct hit testing. AppKit menu tracking/return remains a GUI check.
        return NativeControlMeasurement(buttonRect: buttonRect, alignmentRect: alignmentRect,
                                        popupAnchor: popupAnchor)
    }

    private func settledNativeButton<Content: View>(
        in hosting: NSHostingView<Content>
    ) async throws -> IslandToolMenu.ToolButton {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var previousRect: CGRect?
        var stableSamples = 0
        repeat {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            if let button = nativeButton(in: hosting) {
                let rect = button.convert(button.bounds, to: hosting)
                if rect.width > 0, rect.height > 0, rect == previousRect {
                    stableSamples += 1
                    if stableSamples >= 3 { return button }
                } else {
                    stableSamples = 0
                }
                previousRect = rect
            }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        XCTFail("The real IslandToolMenu native button did not settle in the controlled window.")
        throw NativeControlTestError.layoutDidNotSettle
    }

    private func nativeButton(in view: NSView) -> IslandToolMenu.ToolButton? {
        if let button = view as? IslandToolMenu.ToolButton { return button }
        return view.subviews.lazy.compactMap { self.nativeButton(in: $0) }.first
    }

    private func environment(width: CGFloat, height: CGFloat,
                             notchWidth: CGFloat, notchHeight: CGFloat) -> ScreenEnvironment {
        let sideWidth = (width - notchWidth) / 2
        let auxiliaryY = height - notchHeight
        return ScreenEnvironment(
            displayID: 1,
            name: "Controlled Native Control Display",
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            visibleFrame: CGRect(x: 0, y: 0, width: width, height: height - notchHeight),
            safeAreaInsets: ScreenEdgeInsets(top: notchHeight),
            auxiliaryTopLeftArea: CGRect(x: 0, y: auxiliaryY, width: sideWidth, height: notchHeight),
            auxiliaryTopRightArea: CGRect(x: sideWidth + notchWidth, y: auxiliaryY,
                                          width: sideWidth, height: notchHeight),
            backingScaleFactor: 2,
            isBuiltIn: true
        )
    }
}

private struct NativeControlMeasurement {
    let buttonRect: CGRect
    let alignmentRect: CGRect
    let popupAnchor: CGPoint
}

private enum NativeControlTestError: Error {
    case layoutDidNotSettle
}
