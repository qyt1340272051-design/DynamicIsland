import AppKit
import SwiftUI

/// Native text and bounds use final display points; no cached control is enlarged.
@MainActor
struct IslandTimerModePicker: NSViewRepresentable {
    @Binding var selection: IslandTimerToolMode

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> ModeControl {
        let control = ModeControl(frame: .zero)
        control.segmentCount = IslandTimerToolMode.allCases.count
        control.trackingMode = .selectOne
        control.segmentStyle = .rounded
        control.segmentDistribution = .fillEqually
        control.refusesFirstResponder = false
        for (index, mode) in IslandTimerToolMode.allCases.enumerated() {
            control.setLabel(mode.title, forSegment: index)
        }
        control.setAccessibilityLabel("计时工具")
        control.setAccessibilityIdentifier("island-timer-mode-picker")
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectionChanged(_:))
        updateNSView(control, context: context)
        return control
    }

    func updateNSView(_ control: ModeControl, context: Context) {
        context.coordinator.selection = $selection
        control.applyLayoutScale(context.environment.islandLayoutScale)
        control.selectedSegment = IslandTimerToolMode.allCases.firstIndex(of: selection) ?? 0
        control.isEnabled = context.environment.isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ModeControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    static func dismantleNSView(_ control: ModeControl, coordinator: Coordinator) {
        control.target = nil
        control.action = nil
    }

    @MainActor
    final class ModeControl: NSSegmentedControl {
        private(set) var layoutScale: CGFloat = 1

        override var intrinsicContentSize: NSSize {
            NSSize(width: 120 * layoutScale, height: 24 * layoutScale)
        }

        override var alignmentRectInsets: NSEdgeInsets {
            NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }

        func applyLayoutScale(_ scale: CGFloat) {
            layoutScale = scale.isFinite && scale > 0 ? scale : 1
            controlSize = layoutScale >= 1.5 ? .large
                : layoutScale >= 1 ? .regular : layoutScale >= 0.8 ? .small : .mini
            font = .systemFont(ofSize: 12 * layoutScale)
            invalidateIntrinsicContentSize()
            setFrameSize(intrinsicContentSize)
            needsDisplay = true
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<IslandTimerToolMode>

        init(selection: Binding<IslandTimerToolMode>) { self.selection = selection }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            let modes = IslandTimerToolMode.allCases
            guard sender.isEnabled, modes.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = modes[sender.selectedSegment]
        }
    }
}
