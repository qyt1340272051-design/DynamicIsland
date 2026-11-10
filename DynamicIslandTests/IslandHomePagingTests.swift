import AppKit
import XCTest
@testable import DynamicIsland

final class IslandHomePagingTests: XCTestCase {
    func testHomeLayersWrapInBothDirectionsAndAcceptExtremeOffsets() {
        XCTAssertEqual(IslandHomeLayer.meetings.stepped(by: 1), .music)
        XCTAssertEqual(IslandHomeLayer.music.stepped(by: -1), .meetings)
        XCTAssertEqual(IslandHomeLayer.calendar.stepped(by: 5), .courses)
        XCTAssertEqual(IslandHomeLayer.courses.stepped(by: -5), .calendar)
        XCTAssertEqual(IslandHomeLayer.music.stepped(by: Int.max), .meetings)
        XCTAssertEqual(IslandHomeLayer.calendar.stepped(by: Int.max), .music)
        for layer in IslandHomeLayer.allCases {
            XCTAssertEqual(layer.stepped(by: 0), layer)
            XCTAssertEqual(layer.stepped(by: 4), layer)
            XCTAssertEqual(layer.stepped(by: -4), layer)
            XCTAssertEqual(layer.stepped(by: Int.min), layer)
        }
    }

    func testAContinuousGestureWrappingTheLastLayerCannotSkipTheFirst() {
        var gesture = IslandHomeSwipeState()
        var layer = IslandHomeLayer.meetings
        if let step = gesture.handle(.init(deltaX: -60, deltaY: 0, phase: .began)).step {
            layer = layer.stepped(by: step)
        }
        XCTAssertEqual(layer, .music)
        XCTAssertNil(gesture.handle(.init(deltaX: -180, deltaY: 0, phase: .changed)).step)
        XCTAssertNil(gesture.handle(.init(deltaX: -180, deltaY: 0, phase: .changed,
                                          hasMomentum: true)).step)
        XCTAssertEqual(layer, .music)
    }

    func testThresholdChangesOnePageAndMomentumCannotChangeAnother() {
        var gesture = IslandHomeSwipeState()
        XCTAssertEqual(gesture.handle(.init(deltaX: -12, deltaY: 1, phase: .began)),
                       .init(consumesEvent: true, step: nil))
        XCTAssertNil(gesture.handle(.init(deltaX: -35, deltaY: 0, phase: .changed)).step)
        XCTAssertEqual(gesture.handle(.init(deltaX: -1, deltaY: 0, phase: .changed)).step, 1)
        XCTAssertNil(gesture.handle(.init(deltaX: -180, deltaY: 0, phase: .changed)).step)
        XCTAssertNil(gesture.handle(.init(deltaX: 160, deltaY: 0, phase: .changed)).step)
        XCTAssertTrue(gesture.handle(.init(deltaX: 0, deltaY: 0, phase: .ended)).consumesEvent)
        XCTAssertEqual(gesture.handle(.init(deltaX: -120, deltaY: 0, phase: .changed,
                                           hasMomentum: true)), .ignored)
        XCTAssertEqual(gesture.handle(.init(deltaX: -120, deltaY: 0, phase: .changed)), .ignored)
    }

    func testVerticalIntentStaysWithAgendaScrollEvenWhenLaterDeltaTurnsHorizontal() {
        var gesture = IslandHomeSwipeState()
        XCTAssertEqual(gesture.handle(.init(deltaX: 2, deltaY: 12, phase: .began)), .ignored)
        XCTAssertEqual(gesture.handle(.init(deltaX: -120, deltaY: 0, phase: .changed)), .ignored)
        XCTAssertEqual(gesture.handle(.init(deltaX: 0, deltaY: 0, phase: .ended)), .ignored)
    }

    func testDiagonalIntentDoesNotStealVerticalScroll() {
        var gesture = IslandHomeSwipeState()
        XCTAssertEqual(gesture.handle(.init(deltaX: -15, deltaY: 14, phase: .began)), .ignored)
        XCTAssertEqual(gesture.handle(.init(deltaX: -40, deltaY: 38, phase: .changed)), .ignored)
        XCTAssertNil(gesture.handle(.init(deltaX: 0, deltaY: 0, phase: .ended)).step)
    }

    func testMouseWheelAndUnphasedTailCannotPage() {
        var gesture = IslandHomeSwipeState()
        XCTAssertEqual(gesture.handle(.init(deltaX: -150, deltaY: 0, phase: .began,
                                           isPrecise: false)), .ignored)
        XCTAssertEqual(gesture.handle(.init(deltaX: -150, deltaY: 0, phase: .changed)), .ignored)
    }

    func testCancelledPartialGestureResetsAndSeparateSwipesCanAlternate() {
        var gesture = IslandHomeSwipeState()
        XCTAssertNil(gesture.handle(.init(deltaX: -30, deltaY: 0, phase: .began)).step)
        XCTAssertNil(gesture.handle(.init(deltaX: -40, deltaY: 0, phase: .cancelled)).step)
        XCTAssertEqual(gesture.handle(.init(deltaX: -20, deltaY: 0, phase: .changed)), .ignored)
        for direction: CGFloat in [1, -1, 1, -1] {
            XCTAssertEqual(gesture.handle(.init(deltaX: 48 * direction, deltaY: 0, phase: .began)).step,
                           direction < 0 ? 1 : -1)
            XCTAssertNil(gesture.handle(.init(deltaX: 0, deltaY: 0, phase: .ended)).step)
        }
    }

    func testExcludedOriginAndLeavingSurfaceRejectTheWholeGesture() {
        var gesture = IslandHomeSwipeState()
        XCTAssertEqual(gesture.handle(.init(deltaX: -60, deltaY: 0, phase: .began,
                                           isEligible: false)), .ignored)
        XCTAssertEqual(gesture.handle(.init(deltaX: -60, deltaY: 0, phase: .changed)), .ignored)
        XCTAssertNil(gesture.handle(.init(deltaX: -20, deltaY: 0, phase: .began)).step)
        XCTAssertEqual(gesture.handle(.init(deltaX: -60, deltaY: 0, phase: .changed,
                                           isEligible: false)), .ignored)
        XCTAssertEqual(gesture.handle(.init(deltaX: -60, deltaY: 0, phase: .changed)), .ignored)
        XCTAssertEqual(gesture.handle(.init(deltaX: -48, deltaY: 0, phase: .began)).step, 1)
    }

    func testNonFiniteDeltaCannotPoisonTheNextGesture() {
        var gesture = IslandHomeSwipeState()
        XCTAssertEqual(gesture.handle(.init(deltaX: .nan, deltaY: 0, phase: .began)), .ignored)
        XCTAssertEqual(gesture.handle(.init(deltaX: -48, deltaY: 0, phase: .began)).step, 1)
    }

    @MainActor
    func testObservationBackgroundDoesNotInterceptControlsAndDetachRemovesMonitor() {
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 150))
        let monitor = IslandHomeScrollMonitorView(frame: root.bounds)
        root.addSubview(monitor)
        let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.frame = CGRect(x: 20, y: 20, width: 200, height: 25)
        root.addSubview(slider)
        let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }
        monitor.isPagingEnabled = true
        XCTAssertNil(monitor.hitTest(.init(x: 50, y: 30)))
        XCTAssertTrue(root.hitTest(.init(x: 50, y: 30)) === slider)
        XCTAssertFalse(monitor.isGestureEligible(at: .init(x: 50, y: 30), in: window),
                       "Scrolling a native music slider must not turn the page.")
        XCTAssertTrue(monitor.isGestureEligible(at: .init(x: 50, y: 100), in: window))
        XCTAssertFalse(monitor.isGestureEligible(at: .init(x: 310, y: 100), in: window))
        XCTAssertFalse(monitor.isGestureEligible(at: .init(x: 50, y: 100), in: nil))
        monitor.exclusionRects = [CGRect(x: 20, y: 35, width: 200, height: 30)]
        XCTAssertFalse(monitor.isGestureEligible(at: .init(x: 50, y: 100), in: window),
                       "Custom slider exclusions use top-left SwiftUI coordinates.")
        monitor.exclusionRects = []
        monitor.isPagingEnabled = false
        XCTAssertFalse(monitor.isGestureEligible(at: .init(x: 50, y: 100), in: window))
        monitor.removeFromSuperview()
        XCTAssertNil(monitor.window)
        // Cleanup is idempotent when SwiftUI dismantles an already-detached view.
        monitor.stopMonitoring()
    }
}
