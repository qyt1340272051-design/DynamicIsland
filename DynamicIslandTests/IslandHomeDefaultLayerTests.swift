import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandHomeDefaultLayerTests: XCTestCase {
    func testDefaultLayerRestoresEachChoiceAndFallsBackForUnknownSavedValues() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        XCTAssertEqual(fixture.settings.defaultLayer, .music)
        fixture.settings.showsLayerButtons = false
        for layer in IslandHomeLayer.allCases {
            fixture.settings.defaultLayer = layer
            let restored = IslandHomeSettings(defaults: fixture.defaults)
            XCTAssertEqual(restored.defaultLayer, layer)
            XCTAssertFalse(restored.showsLayerButtons)
        }
        fixture.defaults.set("removed-page", forKey: IslandHomeSettings.defaultLayerKey)
        XCTAssertEqual(IslandHomeSettings(defaults: fixture.defaults).defaultLayer, .music)
    }

    func testEachFreshOpeningUsesSavedLayerAndExpandedNavigationStaysManual() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        for layer in IslandHomeLayer.allCases {
            fixture.settings.defaultLayer = layer
            model.setHovering(true)
            XCTAssertEqual(model.homeLayer, layer)
            let manualLayer: IslandHomeLayer = layer == .meetings ? .courses : .meetings
            model.selectHomeLayer(manualLayer)
            model.setHovering(true)
            XCTAssertEqual(model.homeLayer, manualLayer, "Repeated pointer samples must preserve the user's page.")
            for surface in [IslandExpandedSurface.tools, .utilities, .fileTray] {
                model.selectExpandedSurface(surface)
                model.selectExpandedSurface(.music)
                XCTAssertEqual(model.homeLayer, manualLayer)
            }
            model.endHovering()
            XCTAssertEqual(model.presentationState, .compact)
            XCTAssertEqual(model.homeLayer, manualLayer, "The page resets on opening, not while folding.")
            model.setHovering(true)
            XCTAssertEqual(model.homeLayer, layer)
            model.endHovering()
        }
    }

    func testChangingPreferenceWhileExpandedAppliesOnlyOnTheNextOpening() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.model.setHovering(true)
        fixture.model.selectHomeLayer(.courses)
        fixture.settings.defaultLayer = .calendar
        XCTAssertEqual(fixture.model.homeLayer, .courses)
        fixture.model.endHovering()
        fixture.model.setHovering(true)
        XCTAssertEqual(fixture.model.homeLayer, .calendar)
    }

    func testDelayedHoverAppliesDefaultOnlyAfterAnActualExpansion() async throws {
        let fixture = try makeFixture(hoverDelay: 30_000_000)
        defer { fixture.cleanup() }
        fixture.settings.defaultLayer = .meetings
        fixture.model.selectHomeLayer(.calendar)
        fixture.model.beginHoveringAfterDelay()
        XCTAssertEqual(fixture.model.presentationState, .compact)
        XCTAssertEqual(fixture.model.homeLayer, .calendar)
        fixture.model.endHovering()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fixture.model.presentationState, .compact)
        XCTAssertEqual(fixture.model.homeLayer, .calendar)

        fixture.model.beginHoveringAfterDelay()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while fixture.model.presentationState == .compact {
            guard ContinuousClock.now < deadline else { throw HomeDefaultLayerTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(fixture.model.homeLayer, .meetings)
        fixture.model.selectHomeLayer(.courses)
        fixture.model.beginHoveringAfterDelay()
        XCTAssertEqual(fixture.model.homeLayer, .courses)
    }

    func testDefaultDoesNotOverrideActivityTimerOrDragRouting() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        fixture.settings.defaultLayer = .calendar
        model.activitySurfaceForExpansion = { .utilities }
        model.setHovering(true)
        XCTAssertEqual(model.expandedSurface, .utilities)
        XCTAssertEqual(model.homeLayer, .calendar)
        model.selectExpandedSurface(.music)
        XCTAssertEqual(model.homeLayer, .calendar)
        model.endHovering()

        model.activitySurfaceForExpansion = nil
        let start = Date()
        model.timerTools.selectedMode = .countdown
        model.timerTools.startSelectedTimer(at: start)
        model.setHovering(true)
        XCTAssertEqual(model.expandedSurface, .tools)
        model.endHovering()
        model.timerTools.refresh(at: start.addingTimeInterval(model.timerTools.countdownDuration))
        XCTAssertTrue(model.isTimerCompletionPresented)
        XCTAssertEqual(model.expandedSurface, .tools)
        XCTAssertEqual(model.homeLayer, .calendar)
        model.acknowledgeTimerCompletion()
        XCTAssertEqual(model.presentationState, .compact)

        model.setDragging(true)
        XCTAssertEqual(model.presentationState, .dragging)
        XCTAssertEqual(model.expandedSurface, .fileTray)
        XCTAssertEqual(model.homeLayer, .calendar)
        model.setHovering(true)
        XCTAssertEqual(model.expandedSurface, .fileTray)
        model.setDragging(false)
    }

    func testLockedTrayPointerReentryDoesNotCountAsAFreshOpening() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        fixture.settings.defaultLayer = .calendar
        model.setHovering(true)
        model.selectHomeLayer(.meetings)
        model.selectExpandedSurface(.fileTray)
        model.toggleFileTrayLock()
        model.endHovering()
        XCTAssertEqual(model.presentationState, .expanded)
        model.setHovering(true)
        model.selectExpandedSurface(.music)
        XCTAssertEqual(model.homeLayer, .meetings)
        model.toggleFileTrayLock()
    }

    private func makeFixture(hoverDelay: UInt64 = 0) throws -> HomeDefaultLayerFixture {
        let suite = "IslandHomeDefaultLayerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = IslandHomeSettings(defaults: defaults)
        let model = IslandViewModel(volumeService: HomeDefaultLayerVolumeService(),
            fileTrayService: HomeDefaultLayerFileTrayService(), sharingService: HomeDefaultLayerSharingService(),
            musicService: PlaceholderMusicControlService(), hapticFeedbackService: HomeDefaultLayerHapticService(),
            hoverExpansionDelayNanoseconds: hoverDelay, nowPlayingPollIntervalNanoseconds: 60_000_000_000,
            homeSettings: settings)
        return HomeDefaultLayerFixture(model: model, settings: settings, defaults: defaults, suite: suite)
    }
}

@MainActor
private struct HomeDefaultLayerFixture {
    let model: IslandViewModel
    let settings: IslandHomeSettings
    let defaults: UserDefaults
    let suite: String

    func cleanup() {
        model.endHovering()
        model.setIslandPanelVisible(false)
        defaults.removePersistentDomain(forName: suite)
    }
}

private enum HomeDefaultLayerTestError: Error { case timedOut }

private struct HomeDefaultLayerVolumeService: VolumeService {
    func currentVolume() throws -> Float { 0.5 }
    func setVolume(_ volume: Float) throws {}
}

private struct HomeDefaultLayerFileTrayService: FileTrayService {
    func importFiles(from urls: [URL]) throws -> [TrayFileItem] { [] }
    func remove(_ item: TrayFileItem) throws {}
    func clear() throws {}
}

private struct HomeDefaultLayerSharingService: SharingService {
    func share(urls: [URL]) throws {}
}

private struct HomeDefaultLayerHapticService: HapticFeedbackService {
    func performExpansionFeedback() {}
}
