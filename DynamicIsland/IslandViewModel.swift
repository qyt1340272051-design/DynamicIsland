import Combine
import Foundation
import OSLog

public enum IslandPresentationState: Equatable {
    case compact
    case expanded
    case dragging
}

public enum IslandExpandedSurface: Hashable {
    /// Home region, retaining its original identifier for activity routing.
    case music
    case fileTray
    /// Native timers and plugins placed in the timer region.
    case tools
    /// Plugins placed in the other-tools region.
    case utilities
}

/// A system-originated volume change that may be presented as a transient
/// Activity. Local island controls update the same model but suppress their
/// Core Audio echo so dragging the music slider is not interrupted.
public nonisolated struct VolumeActivityEvent: Equatable, Sendable {
    public let volume: Float
    public let isMuted: Bool

    public init(volume: Float, isMuted: Bool) {
        self.volume = min(max(volume, 0), 1)
        self.isMuted = isMuted
    }
}

@MainActor
public final class IslandViewModel: ObservableObject {
    @Published private(set) var isIslandPanelVisible = true

    func setIslandPanelVisible(_ visible: Bool) {
        guard isIslandPanelVisible != visible else { return }
        isIslandPanelVisible = visible
        if visible {
            startNowPlayingPollingIfNeeded()
        } else {
            stopNowPlayingPolling()
            cancelToolMenuInteraction()
        }
    }

    @Published public private(set) var isPointerInside = false
    @Published public private(set) var isHovering = false
    @Published public private(set) var isDragging = false
    @Published public private(set) var isPlaying = false
    @Published public private(set) var nowPlaying: NowPlayingInfo = .empty
    @Published public private(set) var isSeekingPlayback = false
    @Published public private(set) var trayItems: [TrayFileItem] = []
    @Published public private(set) var isFileTrayLocked = false
    @Published public private(set) var expandedSurface: IslandExpandedSurface = .music
    @Published public private(set) var homeLayer: IslandHomeLayer = .music
    @Published public private(set) var displayLayout = IslandDisplayLayout()
    public var compactPanelSize: CGSize { displayLayout.compactSize }
    @Published public private(set) var compactTimerMode: IslandTimerToolMode?
    @Published public private(set) var compactTimerTextWidth: CGFloat = 0
    @Published private(set) var timerShellMode: IslandTimerToolMode = .stopwatch
    @Published public private(set) var isTimerCompletionPresented = false
    @Published public private(set) var volume: Float
    @Published public private(set) var isMuted: Bool
    @Published public private(set) var lastErrorMessage: String?
    @Published public private(set) var musicErrorMessage: String?
    @Published public private(set) var volumeActivityEvent: VolumeActivityEvent?

    public let timerTools: IslandTimerToolsModel
    let calendarAgenda: CalendarAgendaModel
    let homeSettings: IslandHomeSettings

    private let hoverExpansionDelayNanoseconds: UInt64
    private var hoverExpansionTimer: Timer?
    private let toolMenuReturnDelayNanoseconds: UInt64
    private var toolMenuInteractionID: UUID?
    private var isToolMenuTracking = false
    private var toolMenuReturnTask: Task<Void, Never>?
    // The panel owns physical pointer sampling and its containment cache.
    // Reconcile both caches before a menu deadline can collapse the shell.
    var refreshPointerContainmentBeforeToolMenuReturn: (() -> Void)?
    private let volumeService: VolumeService
    private let fileTrayService: FileTrayService
    private let sharingService: SharingService
    private let musicService: MusicControlService
    private var musicSourceObservation: AnyCancellable?
    private var musicSourceGeneration: UInt64 = 0
    private var nowPlayingRefreshSequence: UInt64 = 0
    private var nowPlayingCompletedSequence: UInt64 = 0
    private let musicRefreshLogger = Logger(subsystem: "DynamicIsland", category: "MusicRefresh")
    private let hapticFeedbackService: HapticFeedbackService
    private var volumeObservation: VolumeObservation?
    private var lastAudibleVolume: Float
    private var isExpandedForFeedback = false
    private var ignoresFinishedFileDropUpdates = false
    private var nowPlayingPollTask: Task<Void, Never>?
    private var nowPlayingPollTimer: DispatchSourceTimer?
    private var nowPlayingPollGeneration: UInt64 = 0
    private var playbackProgressTask: Task<Void, Never>?
    private var playbackSeekSession: PlaybackSeekSession?
    private var playbackSeekTask: Task<Void, Never>?
    private var playbackSeekIdleTask: Task<Void, Never>?
    private var playbackSeekTaskGeneration: UInt64?
    private var playbackSeekGeneration: UInt64 = 0
    private var lastPlaybackSeekDispatchAt: Date?
    private var timerSessionObservation: AnyCancellable?
    private var timerModeObservation: AnyCancellable?
    private var timerCompletionObservation: AnyCancellable?
    private var timerTextWidthObservation: AnyCancellable?
    private var pendingVolumeEcho: PendingVolumeEcho?
    private var suppressesHoverExpansionUntilPointerExit = false
    private let nowPlayingPollIntervalNanoseconds: UInt64
    private let playbackProgressIntervalNanoseconds: UInt64 = 250_000_000

    public var presentationState: IslandPresentationState {
        Self.presentationState(
            isDragging: isDragging,
            isHovering: isHovering,
            isFileTrayLocked: isFileTrayLocked,
            isTimerCompletionPresented: isTimerCompletionPresented
        )
    }

    public var canSeekPlayback: Bool {
        nowPlaying.duration > 0 && !nowPlaying.trackIdentifier.isEmpty
    }

    public nonisolated static let defaultHoverExpansionDelayNanoseconds: UInt64 = 350_000_000
    public nonisolated static let defaultToolMenuReturnDelayNanoseconds: UInt64 = 2_000_000_000
    public nonisolated static let volumeAdjustmentStep: Float = 1.0 / 16.0

    public convenience init(musicProviders: OptionalMusicProviderRegistry? = nil) {
        self.init(
            volumeService: CoreAudioVolumeService(),
            fileTrayService: SandboxFileTrayService(),
            sharingService: AirDropSharingService(),
            musicService: musicProviders.map { MusicSourceRouter(registry: $0) as any MusicControlService }
                ?? AppleMusicControlService(),
            hapticFeedbackService: TrackpadHapticFeedbackService(),
            hoverExpansionDelayNanoseconds: IslandViewModel.defaultHoverExpansionDelayNanoseconds
        )
        if let musicProviders {
            musicSourceObservation = musicProviders.$generation.dropFirst().sink { [weak self] _ in
                self?.musicSourceDidChange()
            }
        }
    }

    /// Clear the previous player's identity before another source can receive
    /// a seek or transport action. The router separately rejects stale replies.
    private func musicSourceDidChange() {
        musicSourceGeneration &+= 1
        cancelPlaybackSeek()
        nowPlaying = .empty
        isPlaying = false
        musicErrorMessage = nil
        Task { [weak self] in
            await Task.yield()
            await self?.refreshNowPlaying()
        }
    }

    public init(
        volumeService: VolumeService,
        fileTrayService: FileTrayService,
        sharingService: SharingService,
        musicService: MusicControlService,
        hapticFeedbackService: HapticFeedbackService,
        hoverExpansionDelayNanoseconds: UInt64 = IslandViewModel.defaultHoverExpansionDelayNanoseconds,
        nowPlayingPollIntervalNanoseconds: UInt64 = 1_500_000_000,
        toolMenuReturnDelayNanoseconds: UInt64 = IslandViewModel.defaultToolMenuReturnDelayNanoseconds,
        calendarAgenda: CalendarAgendaModel? = nil,
        homeSettings: IslandHomeSettings? = nil
    ) {
        self.volumeService = volumeService
        self.fileTrayService = fileTrayService
        self.sharingService = sharingService
        self.musicService = musicService
        self.hapticFeedbackService = hapticFeedbackService
        self.timerTools = IslandTimerToolsModel()
        self.calendarAgenda = calendarAgenda ?? CalendarAgendaModel()
        self.homeSettings = homeSettings ?? IslandHomeSettings()
        self.hoverExpansionDelayNanoseconds = hoverExpansionDelayNanoseconds
        self.toolMenuReturnDelayNanoseconds = toolMenuReturnDelayNanoseconds
        self.nowPlayingPollIntervalNanoseconds = nowPlayingPollIntervalNanoseconds
        let initialVolume = Self.clampedVolume((try? volumeService.currentVolume()) ?? 0.5)
        self.volume = initialVolume
        self.isMuted = (try? volumeService.isMuted()) ?? (initialVolume == 0)
        self.lastAudibleVolume = initialVolume > 0 ? initialVolume : 0.5
        startVolumeObservation()
        startTimerToolsObservation()
        startNowPlayingPollingIfNeeded()
    }

    deinit {
        hoverExpansionTimer?.invalidate()
        toolMenuReturnTask?.cancel()
        nowPlayingPollTask?.cancel()
        nowPlayingPollTimer?.cancel()
        playbackProgressTask?.cancel()
        playbackSeekTask?.cancel()
        playbackSeekIdleTask?.cancel()
        timerSessionObservation?.cancel()
        timerModeObservation?.cancel()
        timerCompletionObservation?.cancel()
        timerTextWidthObservation?.cancel()
        volumeObservation?.cancel()
    }

    public static func preview(hoverExpansionDelayNanoseconds: UInt64 = IslandViewModel.defaultHoverExpansionDelayNanoseconds) -> IslandViewModel {
        IslandViewModel(
            volumeService: PreviewVolumeService(),
            fileTrayService: PreviewFileTrayService(),
            sharingService: PreviewSharingService(),
            musicService: PlaceholderMusicControlService(),
            hapticFeedbackService: PreviewHapticFeedbackService(),
            hoverExpansionDelayNanoseconds: hoverExpansionDelayNanoseconds
        )
    }

    public static func presentationState(
        isDragging: Bool,
        isHovering: Bool,
        isFileTrayLocked: Bool = false,
        isTimerCompletionPresented: Bool = false
    ) -> IslandPresentationState {
        if isDragging { return .dragging }
        if isHovering || isFileTrayLocked || isTimerCompletionPresented { return .expanded }
        return .compact
    }

    public func setHovering(_ hovering: Bool) {
        if toolMenuInteractionID != nil {
            if hovering {
                resumeHoveringDuringToolMenuInteraction()
            } else {
                endHovering()
            }
            return
        }
        cancelHoverExpansion()

        if hovering, suppressesHoverExpansionUntilPointerExit {
            return
        }
        if !hovering {
            suppressesHoverExpansionUntilPointerExit = false
        }

        guard isPointerInside != hovering || isHovering != hovering else {
            return
        }
        isPointerInside = hovering
        if hovering, !isDragging, !isFileTrayLocked {
            expandedSurface = preferredSurfaceForExpansion
        }
        isHovering = hovering
        updateExpansionFeedback()
    }

    public func beginHoveringAfterDelay() {
        guard isIslandPanelVisible, !suppressesHoverExpansionUntilPointerExit else {
            return
        }

        if toolMenuInteractionID != nil {
            resumeHoveringDuringToolMenuInteraction()
            return
        }

        if isPointerInside, isHovering || hoverExpansionTimer?.isValid == true {
            return
        }

        cancelHoverExpansion()
        isPointerInside = true
        updateExpansionFeedback(allowsHaptic: false)
        let timer = Timer(timeInterval: Double(hoverExpansionDelayNanoseconds) / 1_000_000_000,
                          repeats: false) { [weak self] timer in
            // This timer belongs to RunLoop.main. A new MainActor Task would
            // wait behind any job synchronously running AppKit's tracking loop.
            MainActor.assumeIsolated {
                guard let self, self.hoverExpansionTimer === timer else { return }
                self.hoverExpansionTimer = nil
                guard self.isIslandPanelVisible, self.isPointerInside,
                      !self.suppressesHoverExpansionUntilPointerExit else { return }
                if !self.isDragging, !self.isFileTrayLocked {
                    self.expandedSurface = self.preferredSurfaceForExpansion
                }
                self.isHovering = true
                self.updateExpansionFeedback()
            }
        }
        hoverExpansionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelHoverExpansion() {
        hoverExpansionTimer?.invalidate()
        hoverExpansionTimer = nil
    }

    public func endHovering() {
        if isSeekingPlayback {
            finishPlaybackSeek(to: nowPlaying.progress)
        }
        cancelHoverExpansion()
        suppressesHoverExpansionUntilPointerExit = false
        guard isPointerInside || isHovering else {
            return
        }
        isPointerInside = false
        // Menu tracking and its bounded return period keep the same expanded
        // publication that Runtime observes, even outside the island's frame.
        if let id = toolMenuInteractionID {
            traceToolMenu("vm.pointerExit.hold", session: id)
            return
        }
        isHovering = false
        updateExpansionFeedback(allowsHaptic: false)
    }

    func beginToolMenuInteraction() -> UUID? {
        guard isIslandPanelVisible, presentationState == .expanded,
              !isDragging, !isTimerCompletionPresented else { return nil }
        cancelHoverExpansion()
        toolMenuReturnTask?.cancel()
        toolMenuReturnTask = nil
        let id = UUID()
        toolMenuInteractionID = id
        isToolMenuTracking = true
        if !isHovering { isHovering = true }
        traceToolMenu("vm.begin", session: id)
        updateExpansionFeedback(allowsHaptic: false)
        return id
    }

    func isToolMenuInteractionCurrent(_ id: UUID) -> Bool {
        toolMenuInteractionID == id && isIslandPanelVisible
    }

    func endToolMenuInteraction(_ id: UUID) {
        guard isToolMenuInteractionCurrent(id), isToolMenuTracking else { return }
        isToolMenuTracking = false
        traceToolMenu("vm.grace.begin", session: id)
        // Always grant the return period, including when the last pointer sample
        // still says inside. Entries never consume or extend this deadline.
        toolMenuReturnTask = Task { [weak self, toolMenuReturnDelayNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: toolMenuReturnDelayNanoseconds)
            } catch { return }
            guard let self, !Task.isCancelled,
                  self.toolMenuInteractionID == id, !self.isToolMenuTracking else { return }
            self.traceToolMenu("vm.grace.pointerRefresh", session: id)
            self.refreshPointerContainmentBeforeToolMenuReturn?()
            // Refreshing may synchronously hide the panel or replace a session.
            guard !Task.isCancelled, self.toolMenuInteractionID == id,
                  !self.isToolMenuTracking else { return }
            self.traceToolMenu("vm.grace.pointerRefreshed", session: id)
            self.toolMenuReturnTask = nil
            self.toolMenuInteractionID = nil
            self.traceToolMenu("vm.grace.expired", session: id)
            if !self.isPointerInside {
                self.isHovering = false
                self.updateExpansionFeedback(allowsHaptic: false)
            }
        }
    }

    func cancelToolMenuInteraction(_ id: UUID) {
        guard toolMenuInteractionID == id else { return }
        cancelToolMenuInteraction()
    }

    func cancelToolMenuInteraction() {
        guard let id = toolMenuInteractionID else { return }
        traceToolMenu("vm.cancel", session: id)
        toolMenuReturnTask?.cancel()
        toolMenuReturnTask = nil
        toolMenuInteractionID = nil
        isToolMenuTracking = false
        if !isPointerInside {
            isHovering = false
            updateExpansionFeedback(allowsHaptic: false)
        }
    }

    private func resumeHoveringDuringToolMenuInteraction() {
        isPointerInside = true
        if let id = toolMenuInteractionID {
            traceToolMenu(isToolMenuTracking ? "vm.pointerEnter.tracking" : "vm.pointerEnter.grace", session: id)
        }
        // Keep the original deadline through transient inside/outside samples.
        // Neither an early entry nor repeated entries may consume or extend it.
        if !isHovering { isHovering = true }
        updateExpansionFeedback(allowsHaptic: false)
    }

    private func traceToolMenu(_ event: String, session: UUID) {
        IslandToolMenuTrace.record(event: event, session: session,
                                  pointerInside: isPointerInside, hovering: isHovering)
    }

    public func setDragging(_ dragging: Bool) {
        guard isDragging != dragging else {
            return
        }
        if dragging {
            cancelToolMenuInteraction()
            if isSeekingPlayback {
                finishPlaybackSeek(to: nowPlaying.progress)
            }
            expandedSurface = .fileTray
        }
        isDragging = dragging
        updateExpansionFeedback()
    }

    public func selectExpandedSurface(_ surface: IslandExpandedSurface) {
        let targetSurface: IslandExpandedSurface = isTimerCompletionPresented ? .tools : surface
        if targetSurface != .tools && targetSurface != .utilities { cancelToolMenuInteraction() }
        if targetSurface != .music, isSeekingPlayback {
            finishPlaybackSeek(to: nowPlaying.progress)
        }
        guard expandedSurface != targetSurface else {
            return
        }
        expandedSurface = targetSurface
    }

    public func selectHomeLayer(_ layer: IslandHomeLayer) {
        guard isIslandPanelVisible, expandedSurface == .music,
              !isDragging, !isTimerCompletionPresented, homeLayer != layer else { return }
        if isSeekingPlayback { finishPlaybackSeek(to: nowPlaying.progress) }
        homeLayer = layer
    }

    public func stepHomeLayer(by offset: Int) {
        selectHomeLayer(homeLayer.stepped(by: offset))
    }

    public func toggleFileTrayLock() {
        isFileTrayLocked.toggle()
        updateExpansionFeedback()
    }

    public func acknowledgeTimerCompletion() {
        guard isTimerCompletionPresented else {
            return
        }

        cancelToolMenuInteraction()
        cancelHoverExpansion()
        timerTools.acknowledgeCompletion()
        isTimerCompletionPresented = false
        isPointerInside = false
        isHovering = false
        suppressesHoverExpansionUntilPointerExit = true
        updateExpansionFeedback(allowsHaptic: false)
    }

    public func beginFileDrop(isAccepted: Bool) {
        ignoresFinishedFileDropUpdates = false
        setDragging(isAccepted)
    }

    public func updateFileDrop(isAccepted: Bool) {
        guard isAccepted else {
            ignoresFinishedFileDropUpdates = false
            setDragging(false)
            return
        }

        guard !ignoresFinishedFileDropUpdates else {
            return
        }

        setDragging(true)
    }

    public func endFileDrop() {
        ignoresFinishedFileDropUpdates = false
        setDragging(false)
    }

    public func finishFileDrop() {
        ignoresFinishedFileDropUpdates = true
        expandedSurface = .fileTray
        setDragging(false)
        isHovering = isPointerInside
        updateExpansionFeedback()
    }

    public func setCompactPanelSize(_ size: CGSize) {
        let layout = IslandDisplayLayout(compactSize: size)
        guard displayLayout != layout else { return }
        displayLayout = layout
    }

    public func setScreenEnvironment(_ environment: ScreenEnvironment) {
        let layout = IslandDisplayLayout(environment: environment)
        guard displayLayout != layout else { return }
        displayLayout = layout
    }

    public func refreshVolume(publishesActivityEvent: Bool = false) {
        do {
            let currentVolume = Self.clampedVolume(try volumeService.currentVolume())
            let currentMutedState = try volumeService.isMuted()
            let didChange = abs(currentVolume - volume) > 0.0001 || currentMutedState != isMuted
            volume = currentVolume
            isMuted = currentMutedState
            if currentVolume > 0 {
                lastAudibleVolume = currentVolume
            }
            if publishesActivityEvent {
                let event = VolumeActivityEvent(volume: currentVolume, isMuted: currentMutedState)
                if pendingVolumeEcho?.matches(event, at: Date()) == true {
                    pendingVolumeEcho = nil
                } else {
                    pendingVolumeEcho = nil
                    if didChange {
                        volumeActivityEvent = event
                    }
                }
            }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    public func setVolume(_ newValue: Float) {
        let clamped = Self.clampedVolume(newValue)
        let previousVolume = volume
        let previousMutedState = isMuted
        let previousLastAudibleVolume = lastAudibleVolume
        volume = clamped
        isMuted = clamped == 0
        if clamped > 0 {
            lastAudibleVolume = clamped
        }
        pendingVolumeEcho = PendingVolumeEcho(
            event: VolumeActivityEvent(volume: clamped, isMuted: clamped == 0),
            expiresAt: Date().addingTimeInterval(1)
        )

        do {
            try volumeService.setVolume(clamped)
            lastErrorMessage = nil
        } catch {
            pendingVolumeEcho = nil
            volume = previousVolume
            isMuted = previousMutedState
            lastAudibleVolume = previousLastAudibleVolume
            lastErrorMessage = error.localizedDescription
        }
    }

    public func decreaseVolume() {
        setVolume(volume - Self.volumeAdjustmentStep)
    }

    public func increaseVolume() {
        setVolume(volume + Self.volumeAdjustmentStep)
    }

    public func toggleMute() {
        let previousVolume = volume
        let previousMutedState = isMuted
        let previousLastAudibleVolume = lastAudibleVolume
        let shouldMute = !isMuted

        do {
            if shouldMute {
                isMuted = true
                try volumeService.setMuted(true)
            } else if volume == 0 {
                let restoredVolume = max(lastAudibleVolume, Self.volumeAdjustmentStep)
                volume = restoredVolume
                isMuted = false
                lastAudibleVolume = restoredVolume
                try volumeService.setVolume(restoredVolume)
            } else {
                isMuted = false
                try volumeService.setMuted(false)
            }
            pendingVolumeEcho = PendingVolumeEcho(
                event: VolumeActivityEvent(volume: volume, isMuted: isMuted),
                expiresAt: Date().addingTimeInterval(1)
            )
            lastErrorMessage = nil
        } catch {
            pendingVolumeEcho = nil
            volume = previousVolume
            isMuted = previousMutedState
            lastAudibleVolume = previousLastAudibleVolume
            lastErrorMessage = error.localizedDescription
        }
    }

    public func importFiles(from urls: [URL]) {
        do {
            let importedItems = try fileTrayService.importFiles(from: urls)
            trayItems.append(contentsOf: importedItems)
            expandedSurface = .fileTray
            isDragging = false
            isHovering = isPointerInside
            updateExpansionFeedback()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            isDragging = false
            isHovering = isPointerInside
            updateExpansionFeedback()
        }
    }

    public func clearTray() {
        do {
            try fileTrayService.clear()
            trayItems.removeAll()
            updateExpansionFeedback()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    public func removeTrayItem(_ item: TrayFileItem) {
        guard let index = trayItems.firstIndex(where: { $0.id == item.id }) else {
            return
        }

        do {
            try fileTrayService.remove(trayItems[index])
            trayItems.remove(at: index)
            updateExpansionFeedback()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    public func shareTrayViaAirDrop() {
        do {
            try sharingService.share(urls: trayItems.map(\.url))
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private enum MusicAction {
        case togglePlayPause
        case skipBackward
        case skipForward
    }

    public func togglePlayPause() {
        performMusicAction(.togglePlayPause)
    }

    public func skipBackward() {
        performMusicAction(.skipBackward)
    }

    public func skipForward() {
        performMusicAction(.skipForward)
    }

    public func updatePlaybackSeek(to progress: Double) {
        guard progress.isFinite else { return }

        if playbackSeekSession == nil {
            guard canSeekPlayback else { return }
            playbackSeekGeneration &+= 1
            lastPlaybackSeekDispatchAt = nil
            playbackSeekSession = PlaybackSeekSession(
                generation: playbackSeekGeneration,
                trackIdentifier: nowPlaying.trackIdentifier,
                isDragging: true,
                pendingPosition: nil
            )
            isSeekingPlayback = true
        }

        guard playbackSeekSession?.trackIdentifier == nowPlaying.trackIdentifier else {
            cancelPlaybackSeek()
            return
        }

        let position = min(max(progress, 0), 1) * nowPlaying.duration
        nowPlaying = nowPlaying.replacing(position: position)
        playbackSeekSession?.isDragging = true
        playbackSeekSession?.pendingPosition = position
        schedulePlaybackSeekIdleFinish()
        startPlaybackSeekTaskIfNeeded()
    }

    public func finishPlaybackSeek(to progress: Double) {
        updatePlaybackSeek(to: progress)
        guard playbackSeekSession != nil else { return }
        playbackSeekIdleTask?.cancel()
        playbackSeekIdleTask = nil
        playbackSeekSession?.isDragging = false
        startPlaybackSeekTaskIfNeeded()
    }

    private func schedulePlaybackSeekIdleFinish() {
        playbackSeekIdleTask?.cancel()
        playbackSeekIdleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled,
                  self.playbackSeekSession?.isDragging == true else { return }
            self.playbackSeekIdleTask = nil
            self.finishPlaybackSeek(to: self.nowPlaying.progress)
        }
    }

    public func refreshNowPlaying(reportError: Bool = true) async {
        guard playbackSeekSession == nil else { return }
        nowPlayingRefreshSequence &+= 1
        let refreshSequence = nowPlayingRefreshSequence
        let seekGeneration = playbackSeekGeneration
        let sourceGeneration = musicSourceGeneration
        let requestStartedAt = Date()
        musicRefreshLogger.debug("begin sequence=\(refreshSequence) compact=\(self.presentationState == .compact)")
        do {
            let refreshedInfo = try await musicService.nowPlaying()
            guard !Task.isCancelled, refreshSequence > nowPlayingCompletedSequence,
                  playbackSeekSession == nil, seekGeneration == playbackSeekGeneration,
                  sourceGeneration == musicSourceGeneration else { return }
            let requestDuration = Date().timeIntervalSince(requestStartedAt)
            let metadataChanged = nowPlaying.trackIdentifier != refreshedInfo.trackIdentifier
                || nowPlaying.title != refreshedInfo.title || nowPlaying.artist != refreshedInfo.artist
                || nowPlaying.album != refreshedInfo.album || nowPlaying.isPlaying != refreshedInfo.isPlaying
            let artworkChanged = nowPlaying.artworkData != refreshedInfo.artworkData
            nowPlayingCompletedSequence = refreshSequence
            nowPlaying = refreshedInfo.advanced(by: requestDuration)
            isPlaying = nowPlaying.isPlaying
            musicErrorMessage = nil
            musicRefreshLogger.debug("applied sequence=\(refreshSequence) compact=\(self.presentationState == .compact) milliseconds=\(requestDuration * 1_000) metadataChanged=\(metadataChanged) artworkChanged=\(artworkChanged)")
        } catch {
            guard !Task.isCancelled, refreshSequence > nowPlayingCompletedSequence,
                  playbackSeekSession == nil, seekGeneration == playbackSeekGeneration,
                  sourceGeneration == musicSourceGeneration else { return }
            nowPlayingCompletedSequence = refreshSequence
            musicRefreshLogger.debug("failed sequence=\(refreshSequence) compact=\(self.presentationState == .compact) milliseconds=\(Date().timeIntervalSince(requestStartedAt) * 1_000)")
            if reportError {
                musicErrorMessage = error.localizedDescription
            }
        }
    }

    private func startPlaybackSeekTaskIfNeeded() {
        // One worker serializes AppleScript commands while newer drag samples replace the pending target.
        guard playbackSeekTask == nil, let session = playbackSeekSession else { return }
        let generation = session.generation
        playbackSeekTaskGeneration = generation
        playbackSeekTask = Task { [weak self] in
            await self?.drainPlaybackSeek(generation: generation)
        }
    }

    private func drainPlaybackSeek(generation: UInt64) async {
        defer {
            if playbackSeekTaskGeneration == generation {
                playbackSeekTask = nil
                playbackSeekTaskGeneration = nil
                if playbackSeekSession?.pendingPosition != nil {
                    startPlaybackSeekTaskIfNeeded()
                }
            }
        }

        while !Task.isCancelled {
            guard var session = playbackSeekSession, session.generation == generation else { return }
            guard let position = session.pendingPosition else {
                if !session.isDragging {
                    playbackSeekSession = nil
                    isSeekingPlayback = false
                    playbackSeekGeneration &+= 1
                    await refreshNowPlaying(reportError: false)
                }
                return
            }

            if session.isDragging, let lastDispatch = lastPlaybackSeekDispatchAt {
                let remaining = 0.12 - Date().timeIntervalSince(lastDispatch)
                if remaining > 0 {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    } catch {
                        return
                    }
                    continue
                }
            }

            session.pendingPosition = nil
            playbackSeekSession = session
            lastPlaybackSeekDispatchAt = Date()
            do {
                let applied = try await musicService.seek(
                    to: position,
                    trackIdentifier: session.trackIdentifier
                )
                guard playbackSeekSession?.generation == generation, !Task.isCancelled else { return }
                if !applied {
                    cancelPlaybackSeek()
                    await refreshAfterCancelledPlaybackSeek()
                    return
                }
            } catch {
                guard playbackSeekSession?.generation == generation, !Task.isCancelled else { return }
                cancelPlaybackSeek()
                let seekError = error.localizedDescription
                let errorGeneration = playbackSeekGeneration
                await refreshAfterCancelledPlaybackSeek()
                if playbackSeekGeneration == errorGeneration {
                    musicErrorMessage = seekError
                }
                return
            }

        }
    }

    private func refreshAfterCancelledPlaybackSeek() async {
        // Cancelling a seek cancels its own worker as well. Recovery must run
        // in a fresh task so adapters that honor cancellation can read again.
        let seekGeneration = playbackSeekGeneration
        let sourceGeneration = musicSourceGeneration
        await Task { [weak self] in
            guard let self, self.playbackSeekGeneration == seekGeneration,
                  self.musicSourceGeneration == sourceGeneration else { return }
            await self.refreshNowPlaying(reportError: false)
        }.value
    }

    private func cancelPlaybackSeek() {
        guard playbackSeekSession != nil else { return }
        playbackSeekGeneration &+= 1
        playbackSeekSession = nil
        isSeekingPlayback = false
        playbackSeekIdleTask?.cancel()
        playbackSeekIdleTask = nil
        playbackSeekTask?.cancel()
        playbackSeekTask = nil
        playbackSeekTaskGeneration = nil
    }

    private func performMusicAction(_ action: MusicAction) {
        cancelPlaybackSeek()
        nowPlayingRefreshSequence &+= 1
        nowPlayingCompletedSequence = nowPlayingRefreshSequence
        let sourceGeneration = musicSourceGeneration
        Task { [weak self] in
            guard let self, sourceGeneration == self.musicSourceGeneration else { return }
            do {
                switch action {
                case .togglePlayPause:
                    try await self.musicService.togglePlayPause()
                case .skipBackward:
                    try await self.musicService.skipBackward()
                case .skipForward:
                    try await self.musicService.skipForward()
                }
                guard sourceGeneration == self.musicSourceGeneration else { return }
                self.expandedSurface = .music
                await self.refreshNowPlaying()
                self.updateExpansionFeedback()
                self.musicErrorMessage = nil
            } catch {
                guard sourceGeneration == self.musicSourceGeneration else { return }
                self.musicErrorMessage = error.localizedDescription
            }
        }
    }

    private func updateExpansionFeedback(allowsHaptic: Bool = true) {
        let isExpanded = presentationState != .compact
        let didExpand = isExpanded && !isExpandedForFeedback
        if didExpand {
            // A fresh opening starts home at the saved choice. Updating only
            // its layer preserves timer, activity and file-tray routing, and
            // switching regions within this opening keeps manual navigation.
            homeLayer = homeSettings.defaultLayer
        }
        if didExpand, allowsHaptic {
            hapticFeedbackService.performExpansionFeedback()
        }
        isExpandedForFeedback = isExpanded
        updateNowPlayingPolling(isExpanded: isExpanded, didExpand: didExpand)
    }

    private func updateNowPlayingPolling(isExpanded: Bool, didExpand: Bool) {
        if isExpanded {
            startPlaybackProgressUpdatesIfNeeded()
            if didExpand {
                Task { [weak self] in
                    self?.refreshVolume()
                    await self?.refreshNowPlaying(reportError: false)
                }
            }
        } else {
            playbackProgressTask?.cancel()
            playbackProgressTask = nil
        }
    }

    private func startNowPlayingPollingIfNeeded() {
        guard nowPlayingPollTimer == nil, isIslandPanelVisible else {
            return
        }

        // Keep the existing cadence, but use a bounded-leeway timer for this
        // visible status surface. Cooperative sleeps may be coalesced much
        // longer while a nonactivating panel is compact in the background.
        let interval = max(1_000_000, nowPlayingPollIntervalNanoseconds)
        nowPlayingPollGeneration &+= 1
        let generation = nowPlayingPollGeneration
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(clamping: interval)),
                       leeway: .nanoseconds(Int(clamping: min(50_000_000, interval / 20))))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.nowPlayingPollGeneration == generation,
                      self.isIslandPanelVisible, self.nowPlayingPollTask == nil else { return }
                // Slow reads skip a tick; never enqueue overlapping polls or
                // replay missed intervals after the helper recovers.
                self.nowPlayingPollTask = Task(priority: .userInitiated) { [weak self] in
                    guard !Task.isCancelled, let self, self.isIslandPanelVisible,
                          self.nowPlayingPollGeneration == generation else { return }
                    await self.refreshNowPlaying(reportError: false)
                    guard self.nowPlayingPollGeneration == generation else { return }
                    self.nowPlayingPollTask = nil
                }
            }
        }
        nowPlayingPollTimer = timer
        timer.resume()
    }

    private func stopNowPlayingPolling() {
        nowPlayingPollGeneration &+= 1
        nowPlayingRefreshSequence &+= 1
        nowPlayingCompletedSequence = nowPlayingRefreshSequence
        nowPlayingPollTimer?.cancel()
        nowPlayingPollTimer = nil
        nowPlayingPollTask?.cancel()
        nowPlayingPollTask = nil
    }

    private func startPlaybackProgressUpdatesIfNeeded() {
        guard playbackProgressTask == nil else {
            return
        }

        let interval = playbackProgressIntervalNanoseconds
        playbackProgressTask = Task { [weak self] in
            var previousTick = Date()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else {
                    return
                }

                let currentTick = Date()
                let elapsed = currentTick.timeIntervalSince(previousTick)
                previousTick = currentTick
                self.advancePlaybackProgress(by: elapsed)
            }
        }
    }

    private func advancePlaybackProgress(by interval: TimeInterval) {
        guard playbackSeekSession == nil, nowPlaying.isPlaying, nowPlaying.duration > 0 else {
            return
        }

        let advancedInfo = nowPlaying.advanced(by: interval)
        guard advancedInfo.position != nowPlaying.position else {
            return
        }
        nowPlaying = advancedInfo
    }

    /// The Host may route a user expansion to the tool visible beside the camera.
    var activitySurfaceForExpansion: (() -> IslandExpandedSurface?)?

    private var preferredSurfaceForExpansion: IslandExpandedSurface {
        if let surface = activitySurfaceForExpansion?() { return surface }
        if compactTimerMode != nil || expandedSurface == .tools {
            return .tools
        }
        if expandedSurface == .utilities { return .utilities }
        return trayItems.isEmpty ? .music : .fileTray
    }

    private func startTimerToolsObservation() {
        // @Published emits before the model's stored value changes. Format the
        // delivered tuple rather than reading compactTimeText from the model.
        // Monospaced digits keep all ticks in a format at the same natural
        // width, so only a width transition invalidates the outer island.
        timerTextWidthObservation = Publishers.CombineLatest3(
            timerTools.$sessionMode, timerTools.$stopwatchElapsed, timerTools.$countdownRemaining
        )
            .map { mode, elapsed, remaining -> CGFloat in
                guard let mode else { return 0 }
                let text = IslandTimerToolsModel.formattedTime(
                    mode == .stopwatch ? elapsed : remaining, showsTenths: mode == .stopwatch
                )
                return IslandCompactLayout.nativeTimerTextWidth(text)
            }
            .removeDuplicates()
            .sink { [weak self] width in
                guard let self, self.compactTimerTextWidth != width else { return }
                self.compactTimerTextWidth = width
            }

        timerModeObservation = timerTools.$selectedMode
            .removeDuplicates()
            .sink { [weak self] mode in
                guard let self, self.timerShellMode != mode else { return }
                self.timerShellMode = mode
            }

        timerSessionObservation = timerTools.$sessionMode
            .removeDuplicates()
            .sink { [weak self] mode in
                self?.compactTimerMode = mode
            }

        timerCompletionObservation = timerTools.$completedMode
            .removeDuplicates()
            .sink { [weak self] mode in
                self?.handleTimerCompletion(mode)
            }
    }

    private func handleTimerCompletion(_ mode: IslandTimerToolMode?) {
        guard let mode else {
            isTimerCompletionPresented = false
            updateExpansionFeedback(allowsHaptic: false)
            return
        }

        cancelHoverExpansion()
        suppressesHoverExpansionUntilPointerExit = false
        timerTools.selectedMode = mode
        expandedSurface = .tools
        isTimerCompletionPresented = true
        cancelToolMenuInteraction()
        updateExpansionFeedback()
    }

    private func startVolumeObservation() {
        volumeObservation = try? volumeService.observeVolumeChanges { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshVolume(publishesActivityEvent: true)
            }
        }
    }

    private nonisolated static func clampedVolume(_ volume: Float) -> Float {
        min(max(volume, 0), 1)
    }
}

private struct PlaybackSeekSession {
    let generation: UInt64
    let trackIdentifier: String
    var isDragging: Bool
    var pendingPosition: TimeInterval?
}

private struct PendingVolumeEcho {
    let event: VolumeActivityEvent
    let expiresAt: Date

    func matches(_ candidate: VolumeActivityEvent, at date: Date) -> Bool {
        date <= expiresAt && abs(event.volume - candidate.volume) <= 0.01
            && event.isMuted == candidate.isMuted
    }
}

private struct PreviewVolumeService: VolumeService {
    func currentVolume() throws -> Float { 0.58 }
    func setVolume(_ volume: Float) throws {}
}

private struct PreviewFileTrayService: FileTrayService {
    func importFiles(from urls: [URL]) throws -> [TrayFileItem] {
        urls.map { url in
            TrayFileItem(url: url, originalURL: url, byteCount: 12_288)
        }
    }

    func clear() throws {}
    func remove(_ item: TrayFileItem) throws {}
}

private struct PreviewSharingService: SharingService {
    func share(urls: [URL]) throws {}
}

private struct PreviewHapticFeedbackService: HapticFeedbackService {
    func performExpansionFeedback() {}
}
