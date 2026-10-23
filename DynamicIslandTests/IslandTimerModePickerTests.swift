import AppKit
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandTimerModePickerTests: XCTestCase {
    func testNativeFontBoundsAndTargetActionBindingAcrossDisplayScales() async throws {
        let scales: [CGFloat] = [0.875, 1, 1.15625, 1.75]
        for scale in scales {
            try await inspectNativePicker(scale: scale)
        }
    }

    private func inspectNativePicker(scale: CGFloat) async throws {
        let model = IslandTimerToolsModel()
        let state = PickerFixtureState()
        let hosting = NSHostingView(rootView: PickerFixture(model: model, state: state, scale: scale))
        hosting.frame = CGRect(x: 0, y: 0, width: 412 * scale, height: 124 * scale)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        let container = NSView(frame: hosting.frame)
        window.contentView = container
        hosting.autoresizingMask = []
        container.addSubview(hosting)
        defer { window.close() }

        let control = try await settledControl(in: hosting, model: model,
                                               phase: "initial scale=\(scale)")
        XCTAssertTrue(control.window === window)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(try XCTUnwrap(control.font).pointSize, 12 * scale, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(control.cell?.font).pointSize, 12 * scale, accuracy: 0.001)
        XCTAssertEqual(control.intrinsicContentSize.width, 120 * scale, accuracy: 0.001)
        XCTAssertEqual(control.intrinsicContentSize.height, 24 * scale, accuracy: 0.001)
        XCTAssertEqual(control.frame.width, 120 * scale, accuracy: 1)
        XCTAssertEqual(control.frame.height, 24 * scale, accuracy: 1)
        XCTAssertEqual(control.bounds.width, 120 * scale, accuracy: 1)
        XCTAssertEqual(control.bounds.height, 24 * scale, accuracy: 1)
        let nativeRect = control.convert(control.bounds, to: hosting)
        XCTAssertEqual(nativeRect.width, control.bounds.width, accuracy: 0.05,
                       "Final display points must reach AppKit without a second composited scale.")
        XCTAssertEqual(nativeRect.height, control.bounds.height, accuracy: 0.05)
        XCTAssertEqual(control.segmentCount, 2)
        XCTAssertEqual(control.label(forSegment: 0), "秒表")
        XCTAssertEqual(control.label(forSegment: 1), "倒计时")
        XCTAssertEqual(control.trackingMode, .selectOne)
        XCTAssertEqual(control.segmentDistribution, .fillEqually)
        XCTAssertFalse(control.refusesFirstResponder)
        XCTAssertTrue(control.isEnabled)
        XCTAssertEqual(control.selectedSegment, 0)

        // Dispatch through the actual NSControl target/action. A standalone
        // coordinator or copied Swift value would not exercise the Host binding.
        let action = try XCTUnwrap(control.action)
        let target = try XCTUnwrap(control.target)
        control.selectedSegment = 1
        XCTAssertTrue(control.sendAction(action, to: target))
        XCTAssertEqual(model.selectedMode, .countdown)
        // Wait until SwiftUI has observed the intermediate countdown value.
        // The control already selected segment 1 imperatively, so that value
        // alone cannot prove its Binding update completed before reversing it.
        _ = try await settledControl(in: hosting, model: model,
                                     phase: "action to countdown scale=\(scale)", matching: {
            $0.selectedSegment == 1 && state.renderedMode == .countdown
        })

        model.selectedMode = .stopwatch
        _ = try await settledControl(in: hosting, model: model,
                                     phase: "model to stopwatch scale=\(scale)", matching: {
            $0.selectedSegment == 0 && state.renderedMode == .stopwatch
        })
        state.isEnabled = false
        let disabled = try await settledControl(in: hosting, model: model,
                                                phase: "disabled environment scale=\(scale)",
                                                matching: { !$0.isEnabled })
        disabled.selectedSegment = 1
        _ = disabled.sendAction(action, to: target)
        XCTAssertEqual(model.selectedMode, .stopwatch,
                       "A disabled native control must not change the timer through its action.")
    }

    private func settledControl<Content: View>(
        in hosting: NSHostingView<Content>,
        model: IslandTimerToolsModel,
        phase: String,
        matching predicate: (IslandTimerModePicker.ModeControl) -> Bool = { _ in true }
    ) async throws -> IslandTimerModePicker.ModeControl {
        for _ in 0..<200 {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            if let control = nativeControl(in: hosting),
               control.bounds.width > 0, control.bounds.height > 0, predicate(control) {
                return control
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let controlState: String
        if let control = nativeControl(in: hosting) {
            controlState = "selected=\(control.selectedSegment) isEnabled=\(control.isEnabled) bounds=\(control.bounds)"
        } else {
            controlState = "control=missing"
        }
        XCTFail("Timer picker phase=\(phase) currentMode=\(model.selectedMode.rawValue) \(controlState)")
        throw PickerTestError.controlDidNotSettle
    }

    private func nativeControl(in view: NSView) -> IslandTimerModePicker.ModeControl? {
        if let control = view as? IslandTimerModePicker.ModeControl { return control }
        return view.subviews.lazy.compactMap { self.nativeControl(in: $0) }.first
    }
}

@MainActor
private final class PickerFixtureState: ObservableObject {
    @Published var isEnabled = true
    var renderedMode: IslandTimerToolMode?
}

@MainActor
private struct PickerFixture: View {
    @ObservedObject var model: IslandTimerToolsModel
    @ObservedObject var state: PickerFixtureState
    let scale: CGFloat

    var body: some View {
        IslandTimerToolsView(model: model, onAcknowledgeCompletion: {})
            .environment(\.islandLayoutScale, scale)
            .environment(\.colorScheme, .dark)
            .disabled(!state.isEnabled)
            .transaction { $0.disablesAnimations = true }
            .onChange(of: model.selectedMode, initial: true) { _, mode in
                state.renderedMode = mode
            }
    }
}

private enum PickerTestError: Error {
    case controlDidNotSettle
}
