import Combine
import Foundation

public enum IslandPresentationState: Equatable {
    case compact
    case expanded
    case dragging
}

public enum IslandExpandedSurface: Hashable {
    case music
    case fileTray
    case tools
}

@MainActor
public final class IslandViewModel: ObservableObject {
    @Published public private(set) var isPointerInside = false
    @Published public private(set) var isHovering = false
    @Published public private(set) var isDragging = false
    @Published public private(set) var isPlaying = false
    @Published public private(set) var nowPlaying: NowPlayingInfo = .empty
    @Published public private(set) var isSeekingPlayback = false
    @Published public private(set) var trayItems: [TrayFileItem] = []
    @Published public private(set) var isFileTrayLocked = false
    @Published public private(set) var expandedSurface: IslandExpandedSurface = .music
    @Published public private(set) var compactPanelSize = IslandPanelGeometry.compactSize
    @Published public private(set) var compactTimerMode: IslandTimerToolMode?
    @Published private(set) var timerShellMode: IslandTimerToolMode = .stopwatch
    @Published public private(set) var isTimerCompletionPresented = false
    @Published public private(set) var volume: Float
    @Published public private(set) var isMuted: Bool
    @Published public private(set) var lastErrorMessage: String?

    public let timerTools: IslandTimerToolsModel

    private let hoverExpansionDelayNanoseconds: UInt64
    private var hoverTask: Task<Void, Never>?
    private let volumeService: VolumeService
    private let fileTrayService: FileTrayService
    private let sharingService: SharingService
    private let musicService: MusicControlService
    private let hapticFeedbackService: HapticFeedbackService
    private var volumeObservation: VolumeObservation?
    private var lastAudibleVolume: Float
    private var isExpandedForFeedback = false
    private var ignoresFinishedFileDropUpdates = false
    private var nowPlayingPollTask: Task<Void, Never>?
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
    private var suppressesHoverExpansionUntilPointerExit = false
    private let nowPlayingPollIntervalNanoseconds: UInt64 = 1_500_000_000
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
    public nonisolated static let volumeAdjustmentStep: Float = 1.0 / 16.0

    public convenience init() {
        self.init(
            volumeService: CoreAudioVolumeService(),
            fileTrayService: SandboxFileTrayService(),
            sharingService: AirDropSharingService(),
            musicService: AppleMusicControlService(),
            hapticFeedbackService: TrackpadHapticFeedbackService(),
            hoverExpansionDelayNanoseconds: IslandViewModel.defaultHoverExpansionDelayNanoseconds
        )
    }

    public init(
        volumeService: VolumeService,
        fileTrayService: FileTrayService,
        sharingService: SharingService,
        musicService: MusicControlService,
        hapticFeedbackService: HapticFeedbackService,
        hoverExpansionDelayNanoseconds: UInt64 = IslandViewModel.defaultHoverExpansionDelayNanoseconds
    ) {
        self.volumeService = volumeService
        self.fileTrayService = fileTrayService
        self.sharingService = sharingService
        self.musicService = musicService
        self.hapticFeedbackService = hapticFeedbackService
        self.timerTools = IslandTimerToolsModel()
        self.hoverExpansionDelayNanoseconds = hoverExpansionDelayNanoseconds
        let initialVolume = Self.clampedVolume((try? volumeService.currentVolume()) ?? 0.5)
        self.volume = initialVolume
        self.isMuted = (try? volumeService.isMuted()) ?? (initialVolume == 0)
        self.lastAudibleVolume = initialVolume > 0 ? initialVolume : 0.5
        startVolumeObservation()
        startTimerToolsObservation()
    }

    deinit {
        hoverTask?.cancel()
        nowPlayingPollTask?.cancel()
        playbackProgressTask?.cancel()
        playbackSeekTask?.cancel()
        playbackSeekIdleTask?.cancel()
        timerSessionObservation?.cancel()
        timerModeObservation?.cancel()
        timerCompletionObservation?.cancel()
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
        hoverTask?.cancel()
        hoverTask = nil

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
        isHovering = hovering
        if hovering, !isDragging, !isFileTrayLocked {
            expandedSurface = preferredSurfaceForExpansion
        }
        updateExpansionFeedback()
    }

    public func beginHoveringAfterDelay() {
        guard !suppressesHoverExpansionUntilPointerExit else {
            return
        }

        if isPointerInside, isHovering || hoverTask != nil {
            return
        }

        hoverTask?.cancel()
        isPointerInside = true
        updateExpansionFeedback(allowsHaptic: false)
        hoverTask = Task { [weak self, hoverExpansionDelayNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: hoverExpansionDelayNanoseconds)
            } catch {
                return
            }

            await MainActor.run {
                guard let self, !Task.isCancelled else {
                    return
                }
                self.hoverTask = nil
                guard self.isPointerInside else {
                    return
                }
                if !self.isDragging, !self.isFileTrayLocked {
                    self.expandedSurface = self.preferredSurfaceForExpansion
                }
                self.isHovering = true
                self.updateExpansionFeedback()
            }
        }
    }

    public func endHovering() {
        if isSeekingPlayback {
            finishPlaybackSeek(to: nowPlaying.progress)
        }
        hoverTask?.cancel()
        hoverTask = nil
        suppressesHoverExpansionUntilPointerExit = false
        guard isPointerInside || isHovering else {
            return
        }
        isPointerInside = false
        isHovering = false
        updateExpansionFeedback(allowsHaptic: false)
    }

    public func setDragging(_ dragging: Bool) {
        guard isDragging != dragging else {
            return
        }
        if dragging {
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
        if targetSurface != .music, isSeekingPlayback {
            finishPlaybackSeek(to: nowPlaying.progress)
        }
        guard expandedSurface != targetSurface else {
            return
        }
        expandedSurface = targetSurface
    }

    public func toggleFileTrayLock() {
        isFileTrayLocked.toggle()
        updateExpansionFeedback()
    }

    public func acknowledgeTimerCompletion() {
        guard isTimerCompletionPresented else {
            return
        }

        hoverTask?.cancel()
        hoverTask = nil
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
        guard compactPanelSize != size else {
            return
        }

        compactPanelSize = size
    }

    public func refreshVolume() {
        do {
            let currentVolume = Self.clampedVolume(try volumeService.currentVolume())
            let currentMutedState = try volumeService.isMuted()
            volume = currentVolume
            isMuted = currentMutedState
            if currentVolume > 0 {
                lastAudibleVolume = currentVolume
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

        do {
            try volumeService.setVolume(clamped)
            lastErrorMessage = nil
        } catch {
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
            lastErrorMessage = nil
        } catch {
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
        let seekGeneration = playbackSeekGeneration
        do {
            let requestStartedAt = Date()
            let refreshedInfo = try await musicService.nowPlaying()
            guard playbackSeekSession == nil, seekGeneration == playbackSeekGeneration else { return }
            let requestDuration = Date().timeIntervalSince(requestStartedAt)
            nowPlaying = refreshedInfo.advanced(by: requestDuration)
            isPlaying = nowPlaying.isPlaying
            lastErrorMessage = nil
        } catch {
            guard playbackSeekSession == nil, seekGeneration == playbackSeekGeneration else { return }
            if reportError {
                lastErrorMessage = error.localizedDescription
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
                    await refreshNowPlaying(reportError: false)
                    return
                }
            } catch {
                guard playbackSeekSession?.generation == generation, !Task.isCancelled else { return }
                cancelPlaybackSeek()
                let seekError = error.localizedDescription
                let errorGeneration = playbackSeekGeneration
                await refreshNowPlaying(reportError: false)
                if playbackSeekGeneration == errorGeneration {
                    lastErrorMessage = seekError
                }
                return
            }

        }
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
        Task { [weak self] in
            guard let self else { return }
            do {
                switch action {
                case .togglePlayPause:
                    try await self.musicService.togglePlayPause()
                case .skipBackward:
                    try await self.musicService.skipBackward()
                case .skipForward:
                    try await self.musicService.skipForward()
                }
                self.expandedSurface = .music
                await self.refreshNowPlaying()
                self.updateExpansionFeedback()
                self.lastErrorMessage = nil
            } catch {
                self.lastErrorMessage = error.localizedDescription
            }
        }
    }

    private func updateExpansionFeedback(allowsHaptic: Bool = true) {
        let isExpanded = presentationState != .compact
        if isExpanded, !isExpandedForFeedback, allowsHaptic {
            hapticFeedbackService.performExpansionFeedback()
        }
        isExpandedForFeedback = isExpanded
        updateNowPlayingPolling(isExpanded: isExpanded)
    }

    private func updateNowPlayingPolling(isExpanded: Bool) {
        if isExpanded {
            startNowPlayingPollingIfNeeded()
        } else {
            nowPlayingPollTask?.cancel()
            nowPlayingPollTask = nil
            playbackProgressTask?.cancel()
            playbackProgressTask = nil
        }
    }

    private func startNowPlayingPollingIfNeeded() {
        startPlaybackProgressUpdatesIfNeeded()

        guard nowPlayingPollTask == nil else {
            return
        }

        Task { [weak self] in
            self?.refreshVolume()
            await self?.refreshNowPlaying(reportError: false)
        }

        let interval = nowPlayingPollIntervalNanoseconds
        nowPlayingPollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                await self?.refreshNowPlaying(reportError: false)
            }
        }
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

    private var preferredSurfaceForExpansion: IslandExpandedSurface {
        if compactTimerMode != nil || expandedSurface == .tools {
            return .tools
        }
        return trayItems.isEmpty ? .music : .fileTray
    }

    private func startTimerToolsObservation() {
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

        hoverTask?.cancel()
        hoverTask = nil
        suppressesHoverExpansionUntilPointerExit = false
        timerTools.selectedMode = mode
        expandedSurface = .tools
        isTimerCompletionPresented = true
        updateExpansionFeedback()
    }

    private func startVolumeObservation() {
        volumeObservation = try? volumeService.observeVolumeChanges { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshVolume()
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
