import AppKit
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandHoverTrackingTests: XCTestCase {
    func testDelayedHoverExpandsDuringNestedAppKitTracking() async {
        let model = IslandViewModel.preview(hoverExpansionDelayNanoseconds: 20_000_000)
        defer { model.endHovering() }
        model.beginHoveringAfterDelay()
        XCTAssertTrue(model.isPointerInside)
        XCTAssertFalse(model.isHovering)

        // AppKit can synchronously track a menu/control while the calling
        // MainActor job is still on the stack. Common-mode input must keep
        // working without waiting for another MainActor Task to be admitted.
        trackAppKit(until: { model.isHovering })

        XCTAssertTrue(model.isHovering)
        XCTAssertEqual(model.presentationState, .expanded)
    }

    func testLeavingDuringTrackingCancelsPendingExpansion() async {
        let model = IslandViewModel.preview(hoverExpansionDelayNanoseconds: 20_000_000)
        model.beginHoveringAfterDelay()
        model.endHovering()
        trackAppKit(for: 0.06)

        XCTAssertFalse(model.isPointerInside)
        XCTAssertFalse(model.isHovering)
        XCTAssertEqual(model.presentationState, .compact)
    }

    func testPanelSamplesPointerExitDuringNestedAppKitTracking() async {
        let model = IslandViewModel.preview()
        let screen = screenEnvironment()
        var pointer = CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 12)
        let (controller, runtime) = panel(model: model, screen: screen, pointer: { pointer })
        defer { controller.hide(); runtime.shutdownPlugins() }
        controller.show()
        model.setHovering(true)
        pointer = CGPoint(x: 10, y: 10)

        trackAppKit(until: { !model.isPointerInside })

        XCTAssertFalse(model.isPointerInside)
        XCTAssertEqual(model.presentationState, .compact)
    }

    func testStationaryPointerRecoversAfterModelAndPanelCacheDiverge() async {
        let model = IslandViewModel.preview(hoverExpansionDelayNanoseconds: 20_000_000)
        let screen = screenEnvironment()
        let pointer = CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 12)
        let (controller, runtime) = panel(model: model, screen: screen, pointer: { pointer })
        defer { controller.hide(); runtime.shutdownPlugins() }
        controller.show()
        model.setHovering(false)
        XCTAssertFalse(model.isPointerInside)

        trackAppKit(until: { model.isHovering })

        XCTAssertTrue(model.isPointerInside)
        XCTAssertEqual(model.presentationState, .expanded)
    }

    func testHideCancelsPendingHoverAndShowCanExpandAgain() async {
        let model = IslandViewModel.preview(hoverExpansionDelayNanoseconds: 20_000_000)
        let screen = screenEnvironment()
        let pointer = CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 12)
        let (controller, runtime) = panel(model: model, screen: screen, pointer: { pointer })
        defer { controller.hide(); runtime.shutdownPlugins() }
        controller.show()
        controller.hide()
        trackAppKit(for: 0.06)
        XCTAssertFalse(model.isHovering)
        controller.show()
        trackAppKit(until: { model.isHovering })
        XCTAssertEqual(model.presentationState, .expanded)
    }

    func testPlayingMusicRepeatedlyExpandsFromBothWingsAndCenterWithoutOscillation() async throws {
        let service = MusicActivityTestService(info: .init(isPlaying: true,
            title: "I Really Want to Stay at Your House", artist: "Rosa Walton / Hallie Coggins",
            album: "Cyberpunk 2077: Radio, Vol. 2 (Original Soundtrack)",
            duration: 300, position: 85, trackIdentifier: "hover-track"))
        let haptics = HoverFeedbackCounter()
        let model = IslandViewModel(volumeService: MusicActivityTestVolume(),
            fileTrayService: MusicActivityTestTray(), sharingService: MusicActivityTestSharing(),
            musicService: service, hapticFeedbackService: haptics,
            hoverExpansionDelayNanoseconds: 20_000_000)
        await model.refreshNowPlaying()

        for gap: CGFloat in [179, 340] {
            let screen = screenEnvironment(gap: gap)
            var pointer = CGPoint(x: 10, y: 10)
            let (controller, runtime) = panel(model: model, screen: screen, pointer: { pointer })
            controller.show()
            let layout = runtime.compactLayout(forBaseSize: model.displayLayout.designCompactSize)
            let center = screen.frame.midX + layout.centerOffset
            let entry = CGRect(x: center - layout.size.width / 2,
                y: screen.frame.maxY - layout.size.height, width: layout.size.width, height: layout.size.height)

            for x in [entry.minX + 1, entry.midX, entry.maxX - 1] {
                let previousFeedback = haptics.count
                pointer = CGPoint(x: x, y: entry.midY)
                trackAppKit(until: { model.isPointerInside })
                // The visible pre-expansion feedback grows downward. Moving
                // into it must not be misread as leaving during expansion.
                pointer.y = entry.minY - 2.5
                trackAppKit(until: { model.isHovering })
                XCTAssertEqual(model.presentationState, .expanded)
                // Stay longer than the shell animation and several pointer
                // samples, catching compact→expanded→compact feedback loops.
                trackAppKit(for: 0.48)
                XCTAssertEqual(model.presentationState, .expanded)
                XCTAssertEqual(haptics.count, previousFeedback + 1)
                pointer = CGPoint(x: 10, y: 10)
                trackAppKit(until: { !model.isPointerInside })
                XCTAssertEqual(model.presentationState, .compact)
            }
            controller.hide()
            runtime.shutdownPlugins()
        }
    }

    private func panel(model: IslandViewModel, screen: ScreenEnvironment,
                       pointer: @escaping () -> CGPoint) -> (IslandPanelController, IslandActivityRuntime) {
        let manager = ScreenManager(notificationCenter: NotificationCenter(), snapshotProvider: {
            ScreenSnapshot(screens: [screen], mainDisplayID: screen.displayID)
        })
        let runtime = IslandActivityRuntime(viewModel: model)
        return (IslandPanelController(viewModel: model, screenManager: manager,
                    activityRuntime: runtime, pointerLocation: pointer), runtime)
    }

    private func screenEnvironment(gap: CGFloat = 179) -> ScreenEnvironment {
        ScreenEnvironment(displayID: 1, name: "Hover fixture",
            frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
            visibleFrame: CGRect(x: 0, y: 0, width: 1470, height: 924),
            safeAreaInsets: ScreenEdgeInsets(top: 32),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 924, width: (1470 - gap) / 2, height: 32),
            auxiliaryTopRightArea: CGRect(x: (1470 + gap) / 2, y: 924, width: (1470 - gap) / 2, height: 32),
            backingScaleFactor: 2, isBuiltIn: true)
    }

    private func trackAppKit(until condition: () -> Bool = { false }, for duration: TimeInterval = 0.25) {
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        let deadline = Date().addingTimeInterval(duration)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .eventTracking, before: min(deadline, Date().addingTimeInterval(0.005)))
        }
    }
}

private final class HoverFeedbackCounter: HapticFeedbackService {
    private(set) var count = 0
    func performExpansionFeedback() { count += 1 }
}
