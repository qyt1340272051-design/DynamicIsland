import Foundation
import XCTest
@testable import DynamicIsland

final class IslandViewModelTests: XCTestCase {
    func testDragStateExpandsIsland() async {
        await MainActor.run {
            let model = IslandViewModel.preview()

            model.setDragging(true)

            XCTAssertTrue(model.isDragging)
            XCTAssertEqual(model.expandedSurface, .fileTray)
            XCTAssertEqual(model.presentationState, .dragging)
        }
    }

    func testPlainHoverUsesMusicSurface() async {
        await MainActor.run {
            let model = IslandViewModel.preview()

            model.setHovering(true)

            XCTAssertEqual(model.expandedSurface, .music)
            XCTAssertEqual(model.presentationState, .expanded)
        }
    }

    func testSelectingExpandedSurfaceSwitchesVisibleSurface() async {
        await MainActor.run {
            let model = IslandViewModel.preview()
            model.setHovering(true)

            model.selectExpandedSurface(.fileTray)
            XCTAssertEqual(model.expandedSurface, .fileTray)

            model.selectExpandedSurface(.tools)
            XCTAssertEqual(model.expandedSurface, .tools)

            model.selectExpandedSurface(.music)
            XCTAssertEqual(model.expandedSurface, .music)
        }
    }

    func testToolsSurfaceIsRestoredAfterIslandReopens() async {
        await MainActor.run {
            let model = IslandViewModel.preview()
            model.setHovering(true)
            model.selectExpandedSurface(.tools)

            model.endHovering()
            model.setHovering(true)

            XCTAssertEqual(model.expandedSurface, .tools)
            model.endHovering()
        }
    }

    func testActiveTimerUsesCompactTimerPresentationAfterIslandShrinks() async {
        await MainActor.run {
            let model = IslandViewModel.preview()
            let start = Date(timeIntervalSinceReferenceDate: 500)
            model.setHovering(true)
            model.selectExpandedSurface(.tools)
            model.timerTools.selectedMode = .countdown
            model.timerTools.startSelectedTimer(at: start)
            model.timerTools.refresh(at: start.addingTimeInterval(60))

            model.endHovering()

            XCTAssertEqual(model.presentationState, .compact)
            XCTAssertEqual(model.compactTimerMode, .countdown)
            XCTAssertEqual(model.timerTools.compactTimeText, "04:00")

            model.timerTools.pauseSelectedTimer(at: start.addingTimeInterval(60))
            XCTAssertEqual(model.compactTimerMode, .countdown)

            model.timerTools.resetSelectedTimer()
            XCTAssertNil(model.compactTimerMode)
        }
    }

    func testTimerCompletionExpandsToolsAndAcknowledgementCollapsesIt() async {
        await MainActor.run {
            let model = IslandViewModel.preview()
            let start = Date(timeIntervalSinceReferenceDate: 750)
            model.timerTools.selectedMode = .pomodoro
            model.timerTools.startSelectedTimer(at: start)
            model.timerTools.refresh(at: start.addingTimeInterval(model.timerTools.pomodoroDuration))

            XCTAssertTrue(model.isTimerCompletionPresented)
            XCTAssertEqual(model.expandedSurface, .tools)
            XCTAssertEqual(model.presentationState, .expanded)

            model.selectExpandedSurface(.music)
            XCTAssertEqual(model.expandedSurface, .tools)

            model.acknowledgeTimerCompletion()

            XCTAssertFalse(model.isTimerCompletionPresented)
            XCTAssertEqual(model.presentationState, .compact)
            XCTAssertNil(model.compactTimerMode)
            XCTAssertEqual(model.timerTools.pomodoroRemaining, model.timerTools.pomodoroDuration)

            model.setHovering(true)
            XCTAssertEqual(model.presentationState, .compact)
            model.endHovering()
            model.setHovering(true)
            XCTAssertEqual(model.presentationState, .expanded)
            model.endHovering()
        }
    }

    func testHoverDoesNotExpandBeforeDelay() async {
        await MainActor.run {
            let model = IslandViewModel.preview(hoverExpansionDelayNanoseconds: 1_000_000_000)

            model.beginHoveringAfterDelay()

            XCTAssertTrue(model.isPointerInside)
            XCTAssertFalse(model.isHovering)
            XCTAssertEqual(model.presentationState, .compact)
            model.endHovering()
        }
    }

    func testDefaultHoverExpansionDelayIsSnappyButDeliberate() {
        let delay = IslandViewModel.defaultHoverExpansionDelayNanoseconds
        XCTAssertGreaterThanOrEqual(delay, 250_000_000)
        XCTAssertLessThanOrEqual(delay, 450_000_000)
    }

    func testHoverExpandsAfterDelay() async throws {
        let model = await MainActor.run {
            let model = IslandViewModel.preview(hoverExpansionDelayNanoseconds: 5_000_000)
            model.beginHoveringAfterDelay()
            return model
        }

        try await Task.sleep(nanoseconds: 30_000_000)

        await MainActor.run {
            XCTAssertTrue(model.isPointerInside)
            XCTAssertTrue(model.isHovering)
            XCTAssertEqual(model.presentationState, .expanded)
            model.endHovering()
        }
    }

    func testRepeatedHoverEnterDoesNotRestartExpansionDelay() async throws {
        let model = await MainActor.run {
            let model = IslandViewModel.preview(hoverExpansionDelayNanoseconds: 20_000_000)
            model.beginHoveringAfterDelay()
            return model
        }

        try await Task.sleep(nanoseconds: 10_000_000)

        await MainActor.run {
            model.beginHoveringAfterDelay()
        }

        try await Task.sleep(nanoseconds: 15_000_000)

        await MainActor.run {
            XCTAssertTrue(model.isHovering)
            XCTAssertEqual(model.presentationState, .expanded)
            model.endHovering()
        }
    }

    func testLeavingBeforeDelayCancelsExpansion() async throws {
        let model = await MainActor.run {
            let model = IslandViewModel.preview(hoverExpansionDelayNanoseconds: 40_000_000)
            model.beginHoveringAfterDelay()
            model.endHovering()
            return model
        }

        try await Task.sleep(nanoseconds: 80_000_000)

        await MainActor.run {
            XCTAssertFalse(model.isPointerInside)
            XCTAssertFalse(model.isHovering)
            XCTAssertEqual(model.presentationState, .compact)
        }
    }

    func testLeavingHoverExpandedStateReturnsToCompactWithSingleHaptic() async throws {
        let haptics = MockHapticFeedbackService()
        let model = await MainActor.run {
            IslandViewModel(
                volumeService: MockVolumeService(),
                fileTrayService: PreviewEmptyFileTrayService(),
                sharingService: MockSharingService(),
                musicService: PlaceholderMusicControlService(),
                hapticFeedbackService: haptics
            )
        }

        await MainActor.run {
            model.setHovering(true)
            XCTAssertEqual(model.presentationState, .expanded)
            XCTAssertEqual(haptics.expansionFeedbackCount, 1)

            model.endHovering()

            XCTAssertEqual(model.presentationState, .compact)
            XCTAssertEqual(haptics.expansionFeedbackCount, 1)
            model.endHovering()
            XCTAssertEqual(model.presentationState, .compact)
            XCTAssertEqual(haptics.expansionFeedbackCount, 1)
        }
    }

    func testHoverExpansionTriggersHapticFeedbackOnce() async throws {
        let haptics = MockHapticFeedbackService()
        let model = await MainActor.run {
            let model = IslandViewModel(
                volumeService: MockVolumeService(),
                fileTrayService: PreviewEmptyFileTrayService(),
                sharingService: MockSharingService(),
                musicService: PlaceholderMusicControlService(),
                hapticFeedbackService: haptics,
                hoverExpansionDelayNanoseconds: 5_000_000
            )
            model.beginHoveringAfterDelay()
            return model
        }

        try await Task.sleep(nanoseconds: 30_000_000)

        await MainActor.run {
            XCTAssertEqual(model.presentationState, .expanded)
            XCTAssertEqual(haptics.expansionFeedbackCount, 1)
            model.setHovering(true)
            XCTAssertEqual(haptics.expansionFeedbackCount, 1)
            model.endHovering()
        }
    }

    func testMusicControlDoesNotKeepIslandExpandedAfterPointerLeaves() async throws {
        let playing = NowPlayingInfo(isPlaying: true, title: "Song", artist: "Artist", album: "Album")
        let model = await MainActor.run {
            IslandViewModel(
                volumeService: MockVolumeService(),
                fileTrayService: PreviewEmptyFileTrayService(),
                sharingService: MockSharingService(),
                musicService: MockMusicControlService(nowPlayingResult: playing),
                hapticFeedbackService: MockHapticFeedbackService()
            )
        }

        await model.refreshNowPlaying()

        await MainActor.run {
            model.setHovering(true)
            XCTAssertEqual(model.presentationState, .expanded)
            XCTAssertTrue(model.isPlaying)

            model.endHovering()

            XCTAssertTrue(model.isPlaying)
            XCTAssertEqual(model.presentationState, .compact)
        }
    }

    func testRefreshNowPlayingUpdatesPlayingStateAndTrackInfo() async throws {
        let playing = NowPlayingInfo(isPlaying: true, title: "Song", artist: "Artist", album: "Album")
        let model = await MainActor.run {
            IslandViewModel(
                volumeService: MockVolumeService(),
                fileTrayService: PreviewEmptyFileTrayService(),
                sharingService: MockSharingService(),
                musicService: MockMusicControlService(nowPlayingResult: playing),
                hapticFeedbackService: MockHapticFeedbackService()
            )
        }

        await model.refreshNowPlaying()

        await MainActor.run {
            XCTAssertTrue(model.isPlaying)
            XCTAssertEqual(model.nowPlaying, playing)
            XCTAssertNil(model.lastErrorMessage)
        }
    }

    func testRefreshNowPlayingReportsAutomationPermissionDenial() async {
        let model = await MainActor.run {
            IslandViewModel(
                volumeService: MockVolumeService(),
                fileTrayService: PreviewEmptyFileTrayService(),
                sharingService: MockSharingService(),
                musicService: FailingMusicControlService(error: .automationPermissionDenied),
                hapticFeedbackService: MockHapticFeedbackService()
            )
        }

        await model.refreshNowPlaying()

        await MainActor.run {
            XCTAssertEqual(
                model.lastErrorMessage,
                MusicControlError.automationPermissionDenied.localizedDescription
            )
        }
    }

    func testMusicButtonsSendPreviousPlayPauseAndNextCommands() async throws {
        let musicService = RecordingMusicControlService()
        let model = await MainActor.run {
            IslandViewModel(
                volumeService: MockVolumeService(),
                fileTrayService: PreviewEmptyFileTrayService(),
                sharingService: MockSharingService(),
                musicService: musicService,
                hapticFeedbackService: MockHapticFeedbackService()
            )
        }

        await MainActor.run { model.skipBackward() }
        try await waitForMusicCommandCount(1, from: musicService)
        await MainActor.run { model.togglePlayPause() }
        try await waitForMusicCommandCount(2, from: musicService)
        await MainActor.run { model.skipForward() }
        try await waitForMusicCommandCount(3, from: musicService)

        let commands = await musicService.recordedCommands()
        XCTAssertEqual(commands, [.previous, .playPause, .next])
    }

    func testExpandedIslandAdvancesPlaybackProgressBetweenMusicPolls() async throws {
        let playing = NowPlayingInfo(
            isPlaying: true,
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 180,
            position: 30
        )
        let model = await MainActor.run {
            IslandViewModel(
                volumeService: MockVolumeService(),
                fileTrayService: PreviewEmptyFileTrayService(),
                sharingService: MockSharingService(),
                musicService: MockMusicControlService(nowPlayingResult: playing),
                hapticFeedbackService: MockHapticFeedbackService()
            )
        }

        await model.refreshNowPlaying()
        await MainActor.run { model.setHovering(true) }
        try await Task.sleep(nanoseconds: 350_000_000)

        await MainActor.run {
            XCTAssertGreaterThan(model.nowPlaying.position, 30.15)
            XCTAssertLessThan(model.nowPlaying.position, 31)
            model.endHovering()
        }
    }

    func testActionExpansionHapticCanFireAgainAfterReturningToCompact() async throws {
        let haptics = MockHapticFeedbackService()
        let model = await MainActor.run {
            IslandViewModel(
                volumeService: MockVolumeService(),
                fileTrayService: PreviewEmptyFileTrayService(),
                sharingService: MockSharingService(),
                musicService: PlaceholderMusicControlService(),
                hapticFeedbackService: haptics,
                hoverExpansionDelayNanoseconds: 1_000_000
            )
        }

        await MainActor.run {
            model.setDragging(true)
            XCTAssertEqual(haptics.expansionFeedbackCount, 1)
            model.setDragging(false)
            model.setDragging(true)
            XCTAssertEqual(haptics.expansionFeedbackCount, 2)
            model.setDragging(false)
        }
    }

    func testImportAddsTrayItemsAndKeepsExpandedWhilePointerRemainsInside() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("note.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "note".write(to: source, atomically: true, encoding: .utf8)

        await MainActor.run {
            let model = IslandViewModel(
                volumeService: MockVolumeService(),
                fileTrayService: SandboxFileTrayService(trayDirectory: root.appendingPathComponent("tray", isDirectory: true)),
                sharingService: MockSharingService(),
                musicService: PlaceholderMusicControlService(),
                hapticFeedbackService: MockHapticFeedbackService()
            )

            model.setHovering(true)
            model.importFiles(from: [source])

            XCTAssertEqual(model.trayItems.count, 1)
            XCTAssertEqual(model.presentationState, .expanded)
            XCTAssertNil(model.lastErrorMessage)
        }
    }

    func testImportedFilesDoNotKeepIslandExpandedAfterPointerLeaves() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("note.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "note".write(to: source, atomically: true, encoding: .utf8)

        await MainActor.run {
            let model = IslandViewModel(
                volumeService: MockVolumeService(),
                fileTrayService: SandboxFileTrayService(trayDirectory: root.appendingPathComponent("tray", isDirectory: true)),
                sharingService: MockSharingService(),
                musicService: PlaceholderMusicControlService(),
                hapticFeedbackService: MockHapticFeedbackService()
            )

            model.importFiles(from: [source])
            model.endHovering()

            XCTAssertEqual(model.trayItems.count, 1)
            XCTAssertEqual(model.presentationState, .compact)
        }
    }

    func testHoverExpansionPrefersFileTrayWhenTrayContainsFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("note.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "note".write(to: source, atomically: true, encoding: .utf8)

        await MainActor.run {
            let model = IslandViewModel(
                volumeService: MockVolumeService(),
                fileTrayService: SandboxFileTrayService(trayDirectory: root.appendingPathComponent("tray", isDirectory: true)),
                sharingService: MockSharingService(),
                musicService: PlaceholderMusicControlService(),
                hapticFeedbackService: MockHapticFeedbackService()
            )

            model.importFiles(from: [source])
            model.selectExpandedSurface(.music)
            model.endHovering()

            model.setHovering(true)

            XCTAssertEqual(model.trayItems.count, 1)
            XCTAssertEqual(model.expandedSurface, .fileTray)
            XCTAssertEqual(model.presentationState, .expanded)
        }
    }

    func testDelayedHoverExpansionPrefersFileTrayWhenTrayContainsFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("note.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "note".write(to: source, atomically: true, encoding: .utf8)
        let model = await MainActor.run {
            let model = IslandViewModel(
                volumeService: MockVolumeService(),
                fileTrayService: SandboxFileTrayService(trayDirectory: root.appendingPathComponent("tray", isDirectory: true)),
                sharingService: MockSharingService(),
                musicService: PlaceholderMusicControlService(),
                hapticFeedbackService: MockHapticFeedbackService(),
                hoverExpansionDelayNanoseconds: 5_000_000
            )
            model.importFiles(from: [source])
            model.selectExpandedSurface(.music)
            model.beginHoveringAfterDelay()
            return model
        }

        try await Task.sleep(nanoseconds: 30_000_000)

        await MainActor.run {
            XCTAssertEqual(model.trayItems.count, 1)
            XCTAssertEqual(model.expandedSurface, .fileTray)
            XCTAssertEqual(model.presentationState, .expanded)
            model.endHovering()
        }
    }

    func testImportAfterDragExitDoesNotReopenIslandWhenPointerIsOutside() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("note.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "note".write(to: source, atomically: true, encoding: .utf8)

        await MainActor.run {
            let model = IslandViewModel(
                volumeService: MockVolumeService(),
                fileTrayService: SandboxFileTrayService(trayDirectory: root.appendingPathComponent("tray", isDirectory: true)),
                sharingService: MockSharingService(),
                musicService: PlaceholderMusicControlService(),
                hapticFeedbackService: MockHapticFeedbackService()
            )

            model.setDragging(true)
            model.endHovering()
            model.setDragging(false)
            model.importFiles(from: [source])

            XCTAssertEqual(model.trayItems.count, 1)
            XCTAssertFalse(model.isPointerInside)
            XCTAssertFalse(model.isHovering)
            XCTAssertEqual(model.presentationState, .compact)
        }
    }

    func testFinishingFileDropImmediatelyClearsDraggingState() async throws {
        await MainActor.run {
            let model = IslandViewModel(
                volumeService: MockVolumeService(),
                fileTrayService: PreviewEmptyFileTrayService(),
                sharingService: MockSharingService(),
                musicService: PlaceholderMusicControlService(),
                hapticFeedbackService: MockHapticFeedbackService()
            )

            model.setDragging(true)
            XCTAssertEqual(model.presentationState, .dragging)
            XCTAssertEqual(model.expandedSurface, .fileTray)

            model.finishFileDrop()

            XCTAssertFalse(model.isDragging)
            XCTAssertEqual(model.presentationState, .compact)
            XCTAssertEqual(model.expandedSurface, .fileTray)
        }
    }

    func testDropUpdatesAfterFinishedDropDoNotRestartDragging() async throws {
        await MainActor.run {
            let model = IslandViewModel(
                volumeService: MockVolumeService(),
                fileTrayService: PreviewEmptyFileTrayService(),
                sharingService: MockSharingService(),
                musicService: PlaceholderMusicControlService(),
                hapticFeedbackService: MockHapticFeedbackService()
            )

            model.beginFileDrop(isAccepted: true)
            XCTAssertEqual(model.presentationState, .dragging)

            model.finishFileDrop()
            model.updateFileDrop(isAccepted: true)

            XCTAssertFalse(model.isDragging)
            XCTAssertEqual(model.presentationState, .compact)
        }
    }

    func testNewFileDropCanStartAfterFinishedDrop() async throws {
        await MainActor.run {
            let model = IslandViewModel(
                volumeService: MockVolumeService(),
                fileTrayService: PreviewEmptyFileTrayService(),
                sharingService: MockSharingService(),
                musicService: PlaceholderMusicControlService(),
                hapticFeedbackService: MockHapticFeedbackService()
            )

            model.beginFileDrop(isAccepted: true)
            model.finishFileDrop()
            model.updateFileDrop(isAccepted: true)
            model.beginFileDrop(isAccepted: true)

            XCTAssertTrue(model.isDragging)
            XCTAssertEqual(model.presentationState, .dragging)
        }
    }

    func testFileDropKeepsFileTraySurfaceWhilePointerRemainsInside() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("note.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "note".write(to: source, atomically: true, encoding: .utf8)

        await MainActor.run {
            let model = IslandViewModel(
                volumeService: MockVolumeService(),
                fileTrayService: SandboxFileTrayService(trayDirectory: root.appendingPathComponent("tray", isDirectory: true)),
                sharingService: MockSharingService(),
                musicService: PlaceholderMusicControlService(),
                hapticFeedbackService: MockHapticFeedbackService()
            )

            model.setHovering(true)
            model.setDragging(true)
            model.finishFileDrop()
            model.importFiles(from: [source])

            XCTAssertEqual(model.trayItems.count, 1)
            XCTAssertEqual(model.expandedSurface, .fileTray)
            XCTAssertEqual(model.presentationState, .expanded)
        }
    }

    func testSetVolumeWritesClampedValuesToVolumeService() async {
        await MainActor.run {
            let volumeService = RecordingVolumeService(volume: 0.5)
            let model = makeModel(volumeService: volumeService)

            model.setVolume(1.4)
            XCTAssertEqual(model.volume, 1, accuracy: 0.0001)
            XCTAssertFalse(model.isMuted)

            model.setVolume(-0.4)
            XCTAssertEqual(model.volume, 0, accuracy: 0.0001)
            XCTAssertTrue(model.isMuted)
            XCTAssertEqual(volumeService.setVolumeValues, [1, 0])
        }
    }

    func testVolumeButtonsAdjustSystemVolumeByOneStep() async {
        await MainActor.run {
            let volumeService = RecordingVolumeService(volume: 0.5)
            let model = makeModel(volumeService: volumeService)

            model.decreaseVolume()
            XCTAssertEqual(model.volume, 0.5 - IslandViewModel.volumeAdjustmentStep, accuracy: 0.0001)

            model.increaseVolume()
            XCTAssertEqual(model.volume, 0.5, accuracy: 0.0001)
            XCTAssertEqual(volumeService.setVolumeValues.count, 2)
            XCTAssertEqual(
                volumeService.setVolumeValues[0],
                0.5 - IslandViewModel.volumeAdjustmentStep,
                accuracy: 0.0001
            )
            XCTAssertEqual(volumeService.setVolumeValues[1], 0.5, accuracy: 0.0001)
        }
    }

    func testMuteButtonTogglesSystemMuteWithoutLosingVolume() async {
        await MainActor.run {
            let volumeService = RecordingVolumeService(volume: 0.42)
            let model = makeModel(volumeService: volumeService)

            model.toggleMute()
            XCTAssertTrue(model.isMuted)
            XCTAssertEqual(model.volume, 0.42, accuracy: 0.0001)

            model.toggleMute()
            XCTAssertFalse(model.isMuted)
            XCTAssertEqual(model.volume, 0.42, accuracy: 0.0001)
            XCTAssertEqual(volumeService.setMutedValues, [true, false])
        }
    }

    func testUnmutingFromZeroRestoresLastAudibleVolume() async {
        await MainActor.run {
            let volumeService = RecordingVolumeService(volume: 0.42)
            let model = makeModel(volumeService: volumeService)

            model.setVolume(0)
            model.toggleMute()

            XCTAssertFalse(model.isMuted)
            XCTAssertEqual(model.volume, 0.42, accuracy: 0.0001)
            XCTAssertEqual(volumeService.setVolumeValues, [0, 0.42])
        }
    }

    func testExternalSystemVolumeChangeRefreshesIslandState() async throws {
        let volumeService = RecordingVolumeService(volume: 0.25)
        let model = await MainActor.run {
            makeModel(volumeService: volumeService)
        }

        volumeService.simulateSystemChange(volume: 0.8, isMuted: true)
        try await Task.sleep(nanoseconds: 10_000_000)

        await MainActor.run {
            XCTAssertEqual(model.volume, 0.8, accuracy: 0.0001)
            XCTAssertTrue(model.isMuted)
            XCTAssertNil(model.lastErrorMessage)
        }
    }

    func testFailedVolumeWriteRollsBackIslandState() async {
        await MainActor.run {
            let volumeService = RecordingVolumeService(volume: 0.5)
            volumeService.setVolumeError = TestVolumeError.writeFailed
            let model = makeModel(volumeService: volumeService)

            model.increaseVolume()

            XCTAssertEqual(model.volume, 0.5, accuracy: 0.0001)
            XCTAssertFalse(model.isMuted)
            XCTAssertEqual(model.lastErrorMessage, TestVolumeError.writeFailed.localizedDescription)
        }
    }

    @MainActor
    private func makeModel(volumeService: VolumeService) -> IslandViewModel {
        IslandViewModel(
            volumeService: volumeService,
            fileTrayService: PreviewEmptyFileTrayService(),
            sharingService: MockSharingService(),
            musicService: PlaceholderMusicControlService(),
            hapticFeedbackService: MockHapticFeedbackService()
        )
    }

    private func waitForMusicCommandCount(
        _ expectedCount: Int,
        from service: RecordingMusicControlService
    ) async throws {
        for _ in 0..<50 {
            if await service.recordedCommands().count >= expectedCount {
                return
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("音乐控制命令未在预期时间内送达")
    }
}

private struct MockVolumeService: VolumeService {
    func currentVolume() throws -> Float { 0.5 }
    func setVolume(_ volume: Float) throws {}
}

private struct MockMusicControlService: MusicControlService {
    let nowPlayingResult: NowPlayingInfo

    func togglePlayPause() async throws {}
    func skipBackward() async throws {}
    func skipForward() async throws {}
    func nowPlaying() async throws -> NowPlayingInfo { nowPlayingResult }
}

private struct FailingMusicControlService: MusicControlService {
    let error: MusicControlError

    func togglePlayPause() async throws { throw error }
    func skipBackward() async throws { throw error }
    func skipForward() async throws { throw error }
    func nowPlaying() async throws -> NowPlayingInfo { throw error }
}

private actor RecordingMusicControlService: MusicControlService {
    enum Command: Equatable, Sendable {
        case previous
        case playPause
        case next
    }

    private var commands: [Command] = []

    func togglePlayPause() async throws {
        commands.append(.playPause)
    }

    func skipBackward() async throws {
        commands.append(.previous)
    }

    func skipForward() async throws {
        commands.append(.next)
    }

    func nowPlaying() async throws -> NowPlayingInfo {
        .empty
    }

    func recordedCommands() -> [Command] {
        commands
    }
}

private struct MockSharingService: SharingService {
    func share(urls: [URL]) throws {}
}

private struct PreviewEmptyFileTrayService: FileTrayService {
    func importFiles(from urls: [URL]) throws -> [TrayFileItem] { [] }
    func clear() throws {}
}

private final class MockHapticFeedbackService: HapticFeedbackService {
    private(set) var expansionFeedbackCount = 0

    func performExpansionFeedback() {
        expansionFeedbackCount += 1
    }
}

private enum TestVolumeError: LocalizedError {
    case writeFailed

    var errorDescription: String? { "测试音量写入失败" }
}

private final class RecordingVolumeService: VolumeService {
    private(set) var volume: Float
    private(set) var muted: Bool
    private(set) var setVolumeValues: [Float] = []
    private(set) var setMutedValues: [Bool] = []
    var setVolumeError: Error?
    private var changeHandler: (@Sendable () -> Void)?

    init(volume: Float, isMuted: Bool = false) {
        self.volume = volume
        self.muted = isMuted
    }

    func currentVolume() throws -> Float { volume }

    func isMuted() throws -> Bool { muted }

    func setVolume(_ volume: Float) throws {
        if let setVolumeError {
            throw setVolumeError
        }
        self.volume = volume
        muted = volume == 0
        setVolumeValues.append(volume)
    }

    func setMuted(_ muted: Bool) throws {
        self.muted = muted
        setMutedValues.append(muted)
    }

    func observeVolumeChanges(_ handler: @escaping @Sendable () -> Void) throws -> VolumeObservation? {
        changeHandler = handler
        return TestVolumeObservation { [weak self] in
            self?.changeHandler = nil
        }
    }

    func simulateSystemChange(volume: Float, isMuted: Bool) {
        self.volume = volume
        muted = isMuted
        changeHandler?()
    }
}

private nonisolated final class TestVolumeObservation: VolumeObservation {
    private var cancellation: (() -> Void)?

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation?()
        cancellation = nil
    }
}
