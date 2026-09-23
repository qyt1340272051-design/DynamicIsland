import AppKit
import Combine
import Foundation
import ImageIO
import OSLog

/// Adapts the existing Apple Music view model to the Activity API. The view
/// model remains the sole owner of polling, seeking, and media commands.
@MainActor
public final class MusicActivityProvider {
    public nonisolated static let activityID = "builtin.music"
    public nonisolated static let source = ActivitySource(kind: .builtIn, identifier: "music")
    public nonisolated static let artworkResourceID = "builtin.music.artwork"
    public nonisolated static let playPauseActionID = "music.playPause"
    public nonisolated static let previousActionID = "music.previous"
    public nonisolated static let nextActionID = "music.next"
    public nonisolated static let seekActionID = "music.seek"
    public nonisolated static let volumeActionID = "music.volume"
    public nonisolated static let muteActionID = "music.mute"
    public nonisolated static let volumeDownActionID = "music.volumeDown"
    public nonisolated static let volumeUpActionID = "music.volumeUp"

    private let viewModel: IslandViewModel
    private let manager: ActivityManager
    private var observations: [AnyCancellable] = []
    private var cachedArtworkData: Data?
    private var cachedArtworkImage: NSImage?
    private var lastPublishedInfo: NowPlayingInfo?
    private var lastPublishedVolume: Float?
    private var lastPublishedMuted: Bool?
    private var lastPublishedError: String?
    private var volume: Float
    private var isMuted: Bool
    private var errorMessage: String?
    private let logger = Logger(subsystem: "DynamicIsland", category: "MusicActivityProvider")

    /// A single decoded image is enough for the currently playing track. The
    /// service already caches the source artwork; this adds a bounded UI cache.
    private static let maximumArtworkBytes = 4 * 1024 * 1024
    private static let maximumArtworkSide = 2_048
    private static let minimumProgressUpdateInterval: TimeInterval = 1

    public init(viewModel: IslandViewModel, manager: ActivityManager) {
        self.viewModel = viewModel
        self.manager = manager
        volume = viewModel.volume
        isMuted = viewModel.isMuted
        errorMessage = viewModel.musicErrorMessage
        observations.append(viewModel.$nowPlaying.dropFirst().sink { [weak self] info in
            self?.synchronizeAfterModelChange(info)
        })
        observations.append(viewModel.$volume.dropFirst().sink { [weak self] volume in
            self?.volume = volume
            self?.synchronizeAfterModelChange(viewModel.nowPlaying)
        })
        observations.append(viewModel.$isMuted.dropFirst().sink { [weak self] muted in
            self?.isMuted = muted
            self?.synchronizeAfterModelChange(viewModel.nowPlaying)
        })
        observations.append(viewModel.$musicErrorMessage.dropFirst().sink { [weak self] message in
            self?.errorMessage = message
            self?.synchronizeAfterModelChange(viewModel.nowPlaying)
        })
        synchronizeAfterModelChange(viewModel.nowPlaying)
    }

    /// Paused tracks remain persistent, but the compact Host may hide them to
    /// preserve the previous compact behavior.
    public var isPlaying: Bool { viewModel.nowPlaying.isPlaying }

    /// The Host retains this registration and unregisters it at teardown.
    @discardableResult
    public func registerActions(with router: ActionRouter) -> UUID {
        router.register(source: Self.source) { [weak self] action in
            guard action.activityID == Self.activityID else { return }
            _ = self?.handle(actionID: action.actionID, value: action.value)
        }
    }

    /// A Host can call this after restoring state. Repeated polls update one
    /// Activity ID; they never enqueue one Activity per song or progress tick.
    public func synchronize() throws {
        try synchronize(viewModel.nowPlaying)
    }

    /// Resolve only this Host-owned resource, never a plugin URL or path.
    public func resolveImage(_ source: IslandNode.ImageSource) -> NSImage? {
        guard source == .brokerResource(id: Self.artworkResourceID) else { return nil }
        return cachedArtworkImage
    }

    /// Invoked after ActionRouter checks the visible Activity generation and
    /// its declared actions. The model keeps the existing throttled seek path.
    @discardableResult
    public func handle(actionID: String, value: IslandRenderActionValue) -> Bool {
        guard let activity = manager.activity(id: Self.activityID),
              activity.source == Self.source,
              activity.actions.contains(where: { $0.id == actionID }) else { return false }
        switch (actionID, value) {
        case (Self.playPauseActionID, .none):
            viewModel.togglePlayPause()
        case (Self.previousActionID, .none):
            viewModel.skipBackward()
        case (Self.nextActionID, .none):
            viewModel.skipForward()
        case (Self.seekActionID, .slider(let progress)):
            guard progress.isFinite, (0...1).contains(progress), viewModel.canSeekPlayback else { return false }
            viewModel.updatePlaybackSeek(to: progress)
        case (Self.seekActionID, .sliderCommit(let progress)):
            guard progress.isFinite, (0...1).contains(progress), viewModel.canSeekPlayback else { return false }
            viewModel.finishPlaybackSeek(to: progress)
        case (Self.volumeActionID, .slider(let level)):
            guard level.isFinite, (0...1).contains(level) else { return false }
            viewModel.setVolume(Float(level))
        case (Self.volumeActionID, .sliderCommit(let level)):
            guard level.isFinite, (0...1).contains(level) else { return false }
            viewModel.setVolume(Float(level))
        case (Self.muteActionID, .none):
            viewModel.toggleMute()
        case (Self.volumeDownActionID, .none):
            viewModel.decreaseVolume()
        case (Self.volumeUpActionID, .none):
            viewModel.increaseVolume()
        default:
            return false
        }
        return true
    }

    private func synchronizeAfterModelChange(_ info: NowPlayingInfo) {
        do {
            try synchronize(info)
        } catch {
            logger.error("Failed to synchronize Music Activity: \(String(describing: error), privacy: .public)")
        }
    }

    private func synchronize(_ info: NowPlayingInfo) throws {
        refreshArtworkIfNeeded(info.artworkData)
        let activity = makeActivity(info)
        let existing = manager.activity(id: Self.activityID)
        if let existing, existing.presentation == activity.presentation,
           existing.actions == activity.actions {
            return
        }

        // The legacy view model animates progress every 250 ms while expanded.
        // Keep media state responsive but do not rebuild the Activity tree at
        // that frequency when the only change is sub-second playback progress.
        if let previous = lastPublishedInfo, existing != nil,
           sameTrackAndControls(previous, info),
           lastPublishedVolume == volume, lastPublishedMuted == isMuted,
           lastPublishedError == errorMessage,
           abs(previous.position - info.position) < Self.minimumProgressUpdateInterval {
            return
        }

        try manager.publish(activity)
        lastPublishedInfo = info
        lastPublishedVolume = volume
        lastPublishedMuted = isMuted
        lastPublishedError = errorMessage
    }

    private func sameTrackAndControls(_ lhs: NowPlayingInfo, _ rhs: NowPlayingInfo) -> Bool {
        lhs.trackIdentifier == rhs.trackIdentifier &&
        lhs.isPlaying == rhs.isPlaying && lhs.title == rhs.title &&
        lhs.artist == rhs.artist && lhs.album == rhs.album &&
        lhs.duration == rhs.duration && lhs.artworkData == rhs.artworkData
    }

    private func refreshArtworkIfNeeded(_ data: Data?) {
        guard data != cachedArtworkData else { return }
        cachedArtworkData = (data?.count ?? 0) <= Self.maximumArtworkBytes ? data : nil
        cachedArtworkImage = nil
        guard let data, data.count <= Self.maximumArtworkBytes,
              let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              width <= Self.maximumArtworkSide, height <= Self.maximumArtworkSide else { return }
        cachedArtworkImage = NSImage(data: data)
    }

    private func makeActivity(_ info: NowPlayingInfo) -> IslandActivity {
        let title = bounded(info.title.isEmpty ? (info.isPlaying ? "正在播放" : "未在播放") : info.title, bytes: 96)
        let artist = bounded(info.artist.isEmpty ? "Apple Music" : info.artist, bytes: 96)
        let album = bounded(info.album, bytes: 64)
        let defaultSubtitle = info.title.isEmpty ? "在 Apple Music 播放后显示曲目信息"
            : (album.isEmpty ? artist : "\(artist) — \(album)")
        let subtitle = errorMessage.map { bounded($0, bytes: 128) } ?? defaultSubtitle
        let minimalArtwork: IslandNode = cachedArtworkImage == nil
            ? .icon(.init(info.isPlaying ? "waveform" : "music.note"))
            : .image(.init(source: .brokerResource(id: Self.artworkResourceID)))
        let compactArtwork: IslandNode = .image(.init(
            source: .brokerResource(id: Self.artworkResourceID), size: .thumbnail
        ))
        let playSymbol = info.isPlaying ? "pause.fill" : "play.fill"
        let controls: [IslandNode] = [
            .button(.init(actionID: Self.previousActionID, label: .icon(.init("backward.fill")), accessibilityLabel: "上一首")),
            .button(.init(actionID: Self.playPauseActionID, label: .icon(.init(playSymbol)), accessibilityLabel: info.isPlaying ? "暂停" : "播放")),
            .button(.init(actionID: Self.nextActionID, label: .icon(.init("forward.fill")), accessibilityLabel: "下一首"))
        ]
        var actions = [
            ActivityAction(id: Self.previousActionID, title: "上一首"),
            ActivityAction(id: Self.playPauseActionID, title: info.isPlaying ? "暂停" : "播放"),
            ActivityAction(id: Self.nextActionID, title: "下一首")
        ]
        var detailRows: [IslandNode] = [
            .text(.init(title)),
            .text(.init(subtitle))
        ]
        if info.duration > 0, !info.trackIdentifier.isEmpty {
            detailRows.append(.slider(.init(title: "播放进度", value: info.progress,
                                            actionID: Self.seekActionID, showsTitle: false)))
            actions.append(ActivityAction(id: Self.seekActionID, title: "调整进度"))
        } else if info.duration > 0 {
            detailRows.append(.progress(.init(info.progress)))
        }
        detailRows.append(.hStack(.init([
            .text(.init(Self.formattedPlaybackTime(info.position))),
            .spacer(.init()),
            .text(.init(info.duration > 0 ? Self.formattedPlaybackTime(info.duration) : "--:--"))
        ])))
        detailRows.append(.hStack(.init([
            .spacer(.init())
        ] + controls + [
            .spacer(.init())
        ])))
        let speakerSymbol: String
        if isMuted { speakerSymbol = "speaker.slash.fill" }
        else if volume < 0.34 { speakerSymbol = "speaker.wave.1.fill" }
        else if volume < 0.67 { speakerSymbol = "speaker.wave.2.fill" }
        else { speakerSymbol = "speaker.wave.3.fill" }
        detailRows.append(.hStack(.init([
            .button(.init(actionID: Self.muteActionID, label: .icon(.init(speakerSymbol)), accessibilityLabel: isMuted ? "取消静音" : "静音")),
            .button(.init(actionID: Self.volumeDownActionID, label: .icon(.init("minus")), accessibilityLabel: "减小音量")),
            .slider(.init(title: "音量", value: Double(volume),
                          actionID: Self.volumeActionID, showsTitle: false)),
            .button(.init(actionID: Self.volumeUpActionID, label: .icon(.init("plus")), accessibilityLabel: "增大音量")),
            .text(.init(isMuted ? "静音" : "\(Int((volume * 100).rounded()))%"))
        ])))
        actions.append(contentsOf: [
            ActivityAction(id: Self.muteActionID, title: isMuted ? "取消静音" : "静音"),
            ActivityAction(id: Self.volumeDownActionID, title: "减小音量"),
            ActivityAction(id: Self.volumeActionID, title: "调整音量"),
            ActivityAction(id: Self.volumeUpActionID, title: "增大音量")
        ])

        let compact: IslandNode = .hStack(.init([
            compactArtwork,
            .spacer(.init()),
            .icon(.init("waveform"))
        ]))
        let presentation = ActivityPresentation(
            title: title,
            subtitle: subtitle,
            symbolName: "music.note",
            progress: info.duration > 0 ? info.progress : nil,
            minimal: minimalArtwork,
            compact: compact,
            expanded: .hStack(.init([
                .image(.init(source: .brokerResource(id: Self.artworkResourceID), size: .artwork)),
                .vStack(.init(detailRows))
            ])),
            showsCompact: info.isPlaying
        )
        return IslandActivity(
            id: Self.activityID,
            source: Self.source,
            priority: .defaultForBuiltIn(.music),
            lifecycle: ActivityLifecycle(policy: .persistent),
            presentation: presentation,
            createdAt: Date(),
            actions: actions
        )
    }

    private func bounded(_ text: String, bytes: Int) -> String {
        var result = ""
        for character in text {
            let part = String(character)
            guard result.utf8.count + part.utf8.count <= bytes else { break }
            result += part
        }
        return result
    }

    private static func formattedPlaybackTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(min(max(seconds.isFinite ? seconds : 0, 0), 359_999).rounded(.down))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remaining = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remaining)
        }
        return String(format: "%d:%02d", minutes, remaining)
    }
}
