import AppKit
import SwiftUI

/// SwiftUI on newer macOS versions draws sliders without NSSlider subviews.
/// Their actual layout anchors keep those controls outside the paging gesture.
struct IslandHomePagingExclusionPreferenceKey: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

/// A gesture ends after one page change, even when the trackpad keeps sending
/// movement or inertial scrolling. Vertical intent remains available to lists.
nonisolated struct IslandHomeSwipeState {
    enum Phase: Sendable { case began, changed, ended, cancelled }

    struct Sample: Sendable {
        var deltaX: CGFloat
        var deltaY: CGFloat
        var phase: Phase
        var isPrecise = true
        var hasMomentum = false
        var isEligible = true
    }

    struct Result: Equatable {
        let consumesEvent: Bool
        let step: Int?
        static let ignored = Result(consumesEvent: false, step: nil)
    }

    private enum Intent { case idle, undecided, horizontal, vertical, rejected }
    private var intent: Intent = .idle
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var didStep = false
    var threshold: CGFloat = 48

    mutating func reset() {
        intent = .idle
        accumulatedX = 0
        accumulatedY = 0
        didStep = false
    }

    mutating func handle(_ sample: Sample) -> Result {
        guard sample.isPrecise, !sample.hasMomentum else {
            reset()
            return .ignored
        }
        if sample.phase == .began {
            reset()
            intent = sample.isEligible ? .undecided : .rejected
        }
        // Starting outside the home surface, or leaving it before commitment,
        // cannot turn the tail of another scroll into a page change.
        guard sample.isEligible else {
            intent = .rejected
            return .ignored
        }
        guard intent != .idle, intent != .rejected else { return .ignored }
        if sample.phase == .ended || sample.phase == .cancelled {
            let result = Result(consumesEvent: intent == .horizontal, step: nil)
            reset()
            return result
        }
        guard sample.deltaX.isFinite, sample.deltaY.isFinite else {
            reset()
            return .ignored
        }
        accumulatedX += sample.deltaX
        accumulatedY += sample.deltaY
        if intent == .undecided {
            let x = abs(accumulatedX), y = abs(accumulatedY)
            if y >= 6, y >= x {
                intent = .vertical
            } else if x >= 6, x >= y * 1.35 {
                intent = .horizontal
            }
        }
        guard intent == .horizontal else { return .ignored }
        guard !didStep, abs(accumulatedX) >= threshold else {
            return Result(consumesEvent: true, step: nil)
        }
        didStep = true
        // Follow the scroll direction reported by macOS, including the user's
        // natural-scrolling preference: content moving left reveals next page.
        return Result(consumesEvent: true, step: accumulatedX < 0 ? 1 : -1)
    }
}

extension View {
    /// Exclusion rectangles use this view's top-left coordinate system. Native
    /// sliders are excluded automatically so music controls retain scrolling.
    func islandHomePaging(enabled: Bool, exclusionRects: [CGRect] = [],
                          onStep: @escaping @MainActor (Int) -> Void) -> some View {
        islandPaging(enabled: enabled, exclusionRects: exclusionRects, onStep: onStep)
    }

    /// Each non-overlapping navigation region owns one paging monitor.
    func islandPaging(enabled: Bool, exclusionRects: [CGRect] = [],
                      onStep: @escaping @MainActor (Int) -> Void) -> some View {
        backgroundPreferenceValue(IslandHomePagingExclusionPreferenceKey.self) { anchors in
            GeometryReader { geometry in
                IslandHomeScrollMonitor(enabled: enabled,
                    exclusionRects: exclusionRects + anchors.map { geometry[$0] }, onStep: onStep)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Keeps native controls and horizontal content scrolling in control of
    /// gestures that begin inside their actual rendered bounds.
    func islandPagingExcluded() -> some View {
        anchorPreference(key: IslandHomePagingExclusionPreferenceKey.self, value: .bounds) { [$0] }
    }
}

private struct IslandHomeScrollMonitor: NSViewRepresentable {
    let enabled: Bool
    let exclusionRects: [CGRect]
    let onStep: @MainActor (Int) -> Void

    func makeNSView(context: Context) -> IslandHomeScrollMonitorView {
        let view = IslandHomeScrollMonitorView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: IslandHomeScrollMonitorView, context: Context) {
        view.isPagingEnabled = enabled
        view.exclusionRects = exclusionRects
        view.onStep = onStep
    }

    static func dismantleNSView(_ view: IslandHomeScrollMonitorView, coordinator: ()) {
        view.stopMonitoring()
    }
}

/// The background participates only in event observation. It never becomes a
/// hit target and never installs a global monitor or captures another window.
final class IslandHomeScrollMonitorView: NSView {
    var isPagingEnabled = false {
        didSet { if !isPagingEnabled { swipe.reset() } }
    }
    var exclusionRects: [CGRect] = []
    var onStep: (@MainActor (Int) -> Void)?
    private var monitor: Any?
    private var swipe = IslandHomeSwipeState()

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumesEvent = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumesEvent ? nil : event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        swipe.reset()
    }

    /// Returns true only for a captured horizontal home-page gesture.
    func handle(_ event: NSEvent) -> Bool {
        guard event.type == .scrollWheel, isPagingEnabled, !isHiddenOrHasHiddenAncestor,
              let window, event.window === window else {
            swipe.reset()
            return false
        }
        let phase: IslandHomeSwipeState.Phase
        if event.phase.contains(.cancelled) { phase = .cancelled }
        else if event.phase.contains(.ended) { phase = .ended }
        else if event.phase.contains(.began) { phase = .began }
        else if event.phase.contains(.changed) { phase = .changed }
        else { return false }

        let result = swipe.handle(.init(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                                       phase: phase, isPrecise: event.hasPreciseScrollingDeltas,
                                       hasMomentum: !event.momentumPhase.isEmpty,
                                       isEligible: isGestureEligible(at: event.locationInWindow, in: window)))
        if let step = result.step { onStep?(step) }
        return result.consumesEvent
    }

    func isGestureEligible(at windowPoint: CGPoint, in eventWindow: NSWindow?) -> Bool {
        guard isPagingEnabled, !isHiddenOrHasHiddenAncestor,
              let window, eventWindow === window else { return false }
        let point = convert(windowPoint, from: nil)
        return bounds.contains(point) && !exclusionRects.contains { $0.contains(point) }
            && !isOverNativeControl(at: windowPoint, in: window)
    }

    private func isOverNativeControl(at windowPoint: CGPoint, in window: NSWindow) -> Bool {
        guard let content = window.contentView else { return false }
        // hitTest takes coordinates in the receiver's superview. The window's
        // content view is the root of that coordinate space.
        let hitPoint = content.superview?.convert(windowPoint, from: nil)
            ?? content.convert(windowPoint, from: nil)
        var hit = content.hitTest(hitPoint)
        while let view = hit {
            if view is NSSlider || view is NSSegmentedControl || view is NSPopUpButton
                || view is NSStepper || view is NSSwitch || view is NSTextView || view is NSTextField {
                return true
            }
            hit = view.superview
        }
        return false
    }
}
