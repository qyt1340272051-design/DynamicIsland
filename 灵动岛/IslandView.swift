import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct IslandView: View {
    @ObservedObject private var viewModel: IslandViewModel
    private static let expandedContentSize = CGSize(width: 480, height: 210)
    private static let compactArtworkSize: CGFloat = 26
    private static let musicArtworkSize: CGFloat = 124
    private static let trayIconSize = CGSize(width: 74, height: 74)

    public init(viewModel: IslandViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack(alignment: .top) {
            islandShell
            islandBody
                .frame(width: contentSize.width, height: contentSize.height)
                .clipShape(RoundedRectangle(cornerRadius: contentClipCornerRadius, style: .continuous))
        }
        .compositingGroup()
        .frame(width: IslandPanelGeometry.expandedSize.width, height: IslandPanelGeometry.expandedSize.height, alignment: .top)
        .clipped()
        .animation(IslandExpansionAnimation.shell, value: isExpanded)
        .animation(.easeInOut(duration: 0.24), value: viewModel.isPlaying)
        .animation(.easeInOut(duration: 0.24), value: viewModel.compactTimerMode)
        .animation(IslandExpansionAnimation.pointerHover, value: viewModel.isPointerInside)
        .onDrop(
            of: [UTType.fileURL, TrayFileDragProvider.localDragType],
            delegate: IslandFileDropDelegate(viewModel: viewModel)
        )
    }

    private var shellSize: CGSize {
        if isExpanded {
            return IslandVisualStyle.expandedShellSize
        }

        let compactSize = compactPresentationSize
        guard viewModel.isPointerInside else {
            return compactSize
        }

        return CGSize(
            width: compactSize.width * IslandExpansionAnimation.pointerHoverScale,
            height: compactSize.height * IslandExpansionAnimation.pointerHoverScale
        )
    }

    private var contentSize: CGSize {
        Self.expandedContentSize
    }

    private var compactPresentationSize: CGSize {
        IslandVisualStyle.compactShellSize(
            baseSize: viewModel.compactPanelSize,
            isPlaying: viewModel.isPlaying,
            hasActiveTimer: viewModel.compactTimerMode != nil
        )
    }

    private var hasCompactContent: Bool {
        viewModel.compactTimerMode != nil || viewModel.isPlaying
    }

    private var shellVerticalOffset: CGFloat {
        -(IslandVisualStyle.expandedShellSize.height - shellSize.height) / 2
    }

    private var shellCornerRadii: (top: CGFloat, bottom: CGFloat) {
        IslandVisualStyle.shellCornerRadii(isExpanded: isExpanded, shellHeight: shellSize.height)
    }

    private var contentClipCornerRadius: CGFloat {
        isExpanded ? IslandVisualStyle.expandedShellCornerRadius : shellCornerRadii.bottom
    }

    private var isExpanded: Bool {
        viewModel.presentationState != .compact
    }

    private var isCompactHovering: Bool {
        !isExpanded && viewModel.isPointerInside
    }

    private var islandShell: some View {
        islandBackground
            .frame(width: IslandVisualStyle.expandedShellSize.width, height: IslandVisualStyle.expandedShellSize.height)
            .offset(y: shellVerticalOffset)
            .shadow(
                color: .black.opacity(IslandVisualStyle.shellShadowOpacity(isCompactHovering: isCompactHovering)),
                radius: IslandVisualStyle.hoverShellShadowRadius,
                y: IslandVisualStyle.hoverShellShadowYOffset
            )
    }

    private var islandBackground: some View {
        IslandShellShape(size: shellSize, topCornerRadius: shellCornerRadii.top, bottomCornerRadius: shellCornerRadii.bottom)
            .fill(Color.black)
            .overlay {
                if viewModel.isDragging {
                    IslandShellShape(size: shellSize, topCornerRadius: shellCornerRadii.top, bottomCornerRadius: shellCornerRadii.bottom)
                        .stroke(Color.accentColor.opacity(IslandVisualStyle.draggingShellStrokeOpacity), lineWidth: 1)
                } else if isExpanded, IslandVisualStyle.expandedShellStrokeOpacity > 0 {
                    IslandShellShape(size: shellSize, topCornerRadius: shellCornerRadii.top, bottomCornerRadius: shellCornerRadii.bottom)
                        .stroke(Color.white.opacity(IslandVisualStyle.expandedShellStrokeOpacity), lineWidth: 1)
                }
            }
    }

    @ViewBuilder
    private var islandBody: some View {
        ZStack(alignment: .top) {
            compactContent
                .frame(width: compactPresentationSize.width, height: compactPresentationSize.height)
                .opacity(
                    IslandVisualStyle.compactContentOpacity(
                        isExpanded: isExpanded,
                        hasCompactContent: hasCompactContent
                    )
                )
                .scaleEffect(isExpanded ? 0.96 : 1, anchor: .center)
                .allowsHitTesting(!isExpanded)

            expandedContent
                .frame(width: Self.expandedContentSize.width, height: Self.expandedContentSize.height)
                .opacity(isExpanded ? 1 : 0)
                .scaleEffect(
                    isExpanded ? IslandExpansionAnimation.expandedContentScale : IslandExpansionAnimation.compactContentScale,
                    anchor: .center
                )
                .allowsHitTesting(isExpanded)
        }
        .animation(isExpanded ? IslandExpansionAnimation.contentReveal : IslandExpansionAnimation.contentDismiss, value: isExpanded)
    }

    @ViewBuilder
    private var compactContent: some View {
        if viewModel.compactTimerMode != nil {
            CompactTimerStatus(model: viewModel.timerTools)
                .transition(.opacity.combined(with: .scale(scale: 0.86)))
        } else if viewModel.isPlaying {
            HStack(spacing: 0) {
                NowPlayingArtwork(
                    artworkData: viewModel.nowPlaying.artworkData,
                    isPlaying: true,
                    size: Self.compactArtworkSize
                )
                .id("compact-\(nowPlayingArtworkIdentity)")

                Spacer(minLength: 0)

                CompactPlaybackIndicator()
            }
            .padding(.horizontal, 8)
            .transition(.opacity.combined(with: .scale(scale: 0.86)))
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(spacing: 12) {
            surfaceSwitcher

            ZStack(alignment: .topLeading) {
                expandedSurfaceContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .animation(IslandSurfaceTransition.animation, value: viewModel.expandedSurface)
        }
        .padding(18)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var expandedSurfaceContent: some View {
        Group {
            switch viewModel.expandedSurface {
            case .music:
                musicExpandedContent
            case .fileTray:
                fileTrayExpandedContent
            case .tools:
                IslandTimerToolsView(
                    model: viewModel.timerTools,
                    onAcknowledgeCompletion: viewModel.acknowledgeTimerCompletion
                )
            }
        }
        .id(viewModel.expandedSurface)
        .transition(IslandSurfaceTransition.content)
    }

    private var surfaceSwitcher: some View {
        HStack(spacing: 8) {
            surfaceButton(surface: .music, title: "音乐", systemName: "music.note")
            surfaceButton(surface: .fileTray, title: "拖盘", systemName: "tray.full")
            surfaceButton(surface: .tools, title: "工具", systemName: "wrench.adjustable.fill")
            Spacer(minLength: 0)
        }
    }

    private var musicExpandedContent: some View {
        HStack(alignment: .top, spacing: 14) {
            NowPlayingArtwork(
                artworkData: viewModel.nowPlaying.artworkData,
                isPlaying: viewModel.isPlaying,
                size: Self.musicArtworkSize
            )
            .id(nowPlayingArtworkIdentity)

            VStack(alignment: .leading, spacing: 4) {
                nowPlayingInfo
                playbackProgress
                playbackControls
                volumeRow

                if let message = viewModel.lastErrorMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.9))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Self.musicArtworkSize, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var fileTrayExpandedContent: some View {
        VStack(spacing: 14) {
            trayArea
            Spacer(minLength: 0)

            if let message = viewModel.lastErrorMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var nowPlayingInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(nowPlayingTitle)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Text(nowPlayingSubtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var playbackControls: some View {
        HStack(spacing: 8) {
            AnimatedTrackSkipButton(
                direction: .backward,
                action: viewModel.skipBackward
            )
            controlButton(
                systemName: viewModel.isPlaying ? "pause.fill" : "play.fill",
                help: viewModel.isPlaying ? "暂停" : "播放",
                action: viewModel.togglePlayPause
            )
            AnimatedTrackSkipButton(
                direction: .forward,
                action: viewModel.skipForward
            )
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var playbackProgress: some View {
        VStack(spacing: 3) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                    Capsule()
                        .fill(viewModel.isPlaying ? Color.green : Color.white.opacity(0.55))
                        .frame(width: proxy.size.width * CGFloat(viewModel.nowPlaying.progress))
                }
            }
            .frame(height: 4)
            .animation(.linear(duration: 0.25), value: viewModel.nowPlaying.progress)

            HStack {
                Text(formattedPlaybackTime(viewModel.nowPlaying.position))
                Spacer(minLength: 0)
                Text(formattedPlaybackDuration)
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.46))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(formattedPlaybackTime(viewModel.nowPlaying.position)) / \(formattedPlaybackDuration)")
    }

    private var nowPlayingTitle: String {
        if !viewModel.nowPlaying.title.isEmpty {
            return viewModel.nowPlaying.title
        }
        return viewModel.isPlaying ? "正在播放" : "未在播放"
    }

    private var nowPlayingSubtitle: String {
        let info = viewModel.nowPlaying
        var parts: [String] = []
        if !info.artist.isEmpty {
            parts.append(info.artist)
        }
        if !info.album.isEmpty {
            parts.append(info.album)
        }
        return parts.isEmpty ? "在 Apple Music 播放后显示曲目信息" : parts.joined(separator: " — ")
    }

    private var nowPlayingArtworkIdentity: String {
        let info = viewModel.nowPlaying
        if !info.trackIdentifier.isEmpty {
            return info.trackIdentifier
        }
        return "\(info.title)|\(info.artist)|\(info.album)"
    }

    private var formattedPlaybackDuration: String {
        guard viewModel.nowPlaying.duration > 0 else {
            return "--:--"
        }
        return formattedPlaybackTime(viewModel.nowPlaying.duration)
    }

    private func formattedPlaybackTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(Int(seconds.rounded(.down)), 0)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private var volumeRow: some View {
        HStack(spacing: 10) {
            muteControlButton
            volumeControlButton(
                systemName: "minus",
                help: "减小音量",
                action: viewModel.decreaseVolume
            )
            .disabled(viewModel.volume <= 0)

            IslandVolumeSlider(
                value: Binding(
                    get: { viewModel.volume },
                    set: { viewModel.setVolume($0) }
                ),
                isMuted: viewModel.isMuted
            )
            .frame(minWidth: 120, maxWidth: .infinity)

            volumeControlButton(
                systemName: "plus",
                help: "增大音量",
                action: viewModel.increaseVolume
            )
            .disabled(viewModel.volume >= 1 && !viewModel.isMuted)

            Text(viewModel.isMuted ? "静音" : "\(Int((viewModel.volume * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 38, alignment: .trailing)
        }
    }

    private var muteControlButton: some View {
        Button(action: viewModel.toggleMute) {
            AnimatedMuteIcon(
                systemName: volumeBaseSystemImage,
                isMuted: viewModel.isMuted
            )
            .frame(width: 28, height: 28)
            .background(Color.white.opacity(viewModel.isMuted ? 0.18 : 0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .help(viewModel.isMuted ? "取消静音" : "静音")
    }

    private var volumeBaseSystemImage: String {
        if viewModel.volume == 0 {
            return "speaker.fill"
        }
        if viewModel.volume < 0.34 {
            return "speaker.wave.1.fill"
        }
        if viewModel.volume < 0.67 {
            return "speaker.wave.2.fill"
        }
        return "speaker.wave.3.fill"
    }

    private func volumeControlButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.78))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var trayArea: some View {
        VStack(spacing: 10) {
            HStack {
                Label(viewModel.isDragging ? "松开以加入文件托盘" : "文件托盘", systemImage: "tray.full")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !viewModel.trayItems.isEmpty {
                    Button(action: viewModel.shareTrayViaAirDrop) {
                        Label("AirDrop", systemImage: "square.and.arrow.up")
                    }
                    Button(action: viewModel.clearTray) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            if viewModel.trayItems.isEmpty {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(viewModel.isDragging ? 0.14 : 0.07))
                    .frame(height: 48)
                    .overlay {
                        Text("拖入文件后可暂存并通过 AirDrop 分享")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.58))
                    }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(viewModel.trayItems) { item in
                            trayIcon(for: item)
                                .onDrag {
                                    TrayFileDragProvider.itemProvider(for: item)
                                }
                                .help(item.displayName)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: Self.trayIconSize.height + 6)
            }
        }
    }

    private func trayIcon(for item: TrayFileItem) -> some View {
        VStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                trayIconArtwork(for: item)

                if !item.formattedSize.isEmpty {
                    Text(item.formattedSize)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.62), in: Capsule())
                        .offset(x: 7, y: 4)
                }
            }

            Text(item.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(width: Self.trayIconSize.width, height: 25, alignment: .top)
        }
        .frame(width: Self.trayIconSize.width, height: Self.trayIconSize.height, alignment: .top)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func trayIconArtwork(for item: TrayFileItem) -> some View {
        switch TrayFileIconKind.kind(for: item) {
        case .imageThumbnail:
            if let image = NSImage(contentsOf: item.url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 0.5)
                    }
            } else {
                finderIcon(for: item)
            }
        case .systemIcon:
            finderIcon(for: item)
        }
    }

    private func controlButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func surfaceButton(surface: IslandExpandedSurface, title: String, systemName: String) -> some View {
        let isSelected = viewModel.expandedSurface == surface
        return Button {
            viewModel.selectExpandedSurface(surface)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(isSelected ? 0.18 : 0.08), in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(isSelected ? 0.22 : 0.08), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .white : .white.opacity(0.68))
        .animation(IslandSurfaceTransition.animation, value: isSelected)
        .help(title)
        .accessibilityLabel(title)
    }

    private func finderIcon(for item: TrayFileItem) -> some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
            .resizable()
            .scaledToFit()
            .frame(width: 44, height: 42)
    }
}

private struct AnimatedTrackSkipButton: View {
    let direction: IslandTrackSkipDirection
    let action: () -> Void

    @State private var animationTrigger = 0

    private var systemName: String {
        direction == .backward ? "backward.fill" : "forward.fill"
    }

    private var accessibilityLabel: String {
        direction == .backward ? "上一首" : "下一首"
    }

    var body: some View {
        Button {
            animationTrigger &+= 1
            action()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.12))

                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .bold))
                    .keyframeAnimator(
                        initialValue: TrackSkipAnimationValues(),
                        trigger: animationTrigger
                    ) { content, value in
                        content
                            .offset(x: value.horizontalOffset)
                            .opacity(value.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.horizontalOffset) {
                            LinearKeyframe(travelOffset, duration: IslandTrackSkipAnimation.exitDuration)
                            MoveKeyframe(resetOffset)
                            LinearKeyframe(0, duration: IslandTrackSkipAnimation.entryDuration)
                        }

                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(0, duration: IslandTrackSkipAnimation.exitDuration)
                            MoveKeyframe(0)
                            LinearKeyframe(1, duration: IslandTrackSkipAnimation.entryDuration)
                        }
                    }
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }

    private var travelOffset: CGFloat {
        IslandTrackSkipAnimation.offset(
            for: direction,
            distance: IslandTrackSkipAnimation.travelDistance
        )
    }

    private var resetOffset: CGFloat {
        IslandTrackSkipAnimation.offset(
            for: direction,
            distance: -IslandTrackSkipAnimation.resetDistance
        )
    }
}

private struct TrackSkipAnimationValues {
    var horizontalOffset: CGFloat = 0
    var opacity: Double = 1
}

private struct CompactTimerStatus: View {
    @ObservedObject var model: IslandTimerToolsModel

    var body: some View {
        if let mode = model.sessionMode {
            HStack(spacing: 0) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint(for: mode))
                    .frame(width: 26, height: 26)
                    .background(tint(for: mode).opacity(0.14), in: Circle())

                Spacer(minLength: 0)

                Text(model.compactTimeText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .frame(width: 58, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(mode.title)，\(model.compactTimeText)")
        }
    }

    private func tint(for mode: IslandTimerToolMode) -> Color {
        switch mode {
        case .stopwatch:
            return .cyan
        case .pomodoro:
            return .red
        case .countdown:
            return .orange
        }
    }
}

private struct CompactPlaybackIndicator: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            HStack(alignment: .center, spacing: IslandCompactPlaybackAnimation.dotSpacing) {
                ForEach(0..<IslandCompactPlaybackAnimation.dotCount, id: \.self) { index in
                    Capsule()
                        .fill(Color.green)
                        .frame(
                            width: IslandCompactPlaybackAnimation.dotWidth,
                            height: IslandCompactPlaybackAnimation.height(
                                for: index,
                                at: context.date.timeIntervalSinceReferenceDate
                            )
                        )
                }
            }
        }
        .frame(
            width: IslandCompactPlaybackAnimation.indicatorWidth,
            height: IslandCompactPlaybackAnimation.maximumHeight
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在播放")
    }
}

private struct NowPlayingArtwork: View {
    let artworkData: Data?
    let isPlaying: Bool
    let size: CGFloat

    @State private var image: NSImage?

    private var cornerRadius: CGFloat {
        min(10, max(3, size * 0.08))
    }

    init(artworkData: Data?, isPlaying: Bool, size: CGFloat) {
        self.artworkData = artworkData
        self.isPlaying = isPlaying
        self.size = size
        _image = State(initialValue: artworkData.flatMap(NSImage.init(data:)))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.09))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: isPlaying ? "waveform" : "music.note")
                    .font(.system(size: max(10, size * 0.25), weight: .semibold))
                    .foregroundStyle(isPlaying ? Color.green : Color.white.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
        }
        .onChange(of: artworkData) { _, newData in
            image = newData.flatMap(NSImage.init(data:))
        }
        .accessibilityHidden(true)
    }
}

private struct IslandVolumeSlider: View {
    @Binding private var value: Float
    let isMuted: Bool

    @State private var displayedValue: CGFloat
    @State private var isDragging = false

    private let thumbDiameter: CGFloat = 14
    private let trackHeight: CGFloat = 4

    init(value: Binding<Float>, isMuted: Bool) {
        _value = value
        self.isMuted = isMuted
        _displayedValue = State(initialValue: Self.clamped(CGFloat(value.wrappedValue)))
    }

    var body: some View {
        GeometryReader { proxy in
            let travelWidth = max(proxy.size.width - thumbDiameter, 0)
            let progress = Self.clamped(displayedValue)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: trackHeight)
                    .padding(.horizontal, thumbDiameter / 2)

                Capsule()
                    .fill(isMuted ? Color.white.opacity(0.3) : Color.accentColor)
                    .frame(width: travelWidth * progress, height: trackHeight)
                    .offset(x: thumbDiameter / 2)

                Circle()
                    .fill(isMuted ? Color.white.opacity(0.78) : Color.white)
                    .overlay {
                        Circle()
                            .stroke(Color.black.opacity(0.18), lineWidth: 0.5)
                    }
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: travelWidth * progress)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        updateValue(at: gesture.location.x, availableWidth: proxy.size.width)
                    }
                    .onEnded { gesture in
                        updateValue(at: gesture.location.x, availableWidth: proxy.size.width)
                        isDragging = false
                    }
            )
        }
        .frame(height: 28)
        .onAppear {
            displayedValue = Self.clamped(CGFloat(value))
        }
        .onChange(of: value) { _, newValue in
            let target = Self.clamped(CGFloat(newValue))
            if isDragging {
                displayedValue = target
            } else {
                withAnimation(IslandVolumeAnimation.sliderTravel) {
                    displayedValue = target
                }
            }
        }
        .animation(IslandVolumeAnimation.muteSlash, value: isMuted)
        .accessibilityElement()
        .accessibilityLabel("系统音量")
        .accessibilityValue(isMuted ? "静音" : "\(Int((value * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                value = Self.clamped(value + IslandViewModel.volumeAdjustmentStep)
            case .decrement:
                value = Self.clamped(value - IslandViewModel.volumeAdjustmentStep)
            @unknown default:
                break
            }
        }
    }

    private func updateValue(at xPosition: CGFloat, availableWidth: CGFloat) {
        let travelWidth = max(availableWidth - thumbDiameter, 1)
        let progress = Self.clamped((xPosition - thumbDiameter / 2) / travelWidth)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayedValue = progress
            value = Float(progress)
        }
    }

    private static func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    private static func clamped(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}

private struct AnimatedMuteIcon: View {
    let systemName: String
    let isMuted: Bool

    var body: some View {
        ZStack {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(
                    Color.white.opacity(isMuted ? IslandVolumeAnimation.muteIconDimmedOpacity : 0.78)
                )

            MuteSlashShape()
                .trim(from: 0, to: isMuted ? 1 : 0)
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
                .shadow(color: Color.accentColor.opacity(isMuted ? 0.45 : 0), radius: 1)
        }
        .frame(width: 17, height: 17)
        .animation(IslandVolumeAnimation.muteSlash, value: isMuted)
    }
}

private struct MuteSlashShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 1.5, y: rect.maxY - 2))
        path.addLine(to: CGPoint(x: rect.maxX - 1.5, y: rect.minY + 2))
        return path
    }
}

private struct IslandFileDropDelegate: DropDelegate {
    let viewModel: IslandViewModel

    func validateDrop(info: DropInfo) -> Bool {
        acceptsExternalFileDrop(info)
    }

    func dropEntered(info: DropInfo) {
        viewModel.beginFileDrop(isAccepted: acceptsExternalFileDrop(info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard acceptsExternalFileDrop(info) else {
            viewModel.updateFileDrop(isAccepted: false)
            return DropProposal(operation: .forbidden)
        }

        viewModel.updateFileDrop(isAccepted: true)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        viewModel.endFileDrop()
    }

    func performDrop(info: DropInfo) -> Bool {
        guard acceptsExternalFileDrop(info) else {
            viewModel.endFileDrop()
            return false
        }

        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else {
            viewModel.endFileDrop()
            return false
        }

        viewModel.finishFileDrop()

        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = DroppedFileURLResolver.fileURL(from: item)
                Task { @MainActor in
                    if let url {
                        viewModel.importFiles(from: [url])
                    } else {
                        viewModel.endFileDrop()
                    }
                }
            }
        }

        return true
    }

    private func acceptsExternalFileDrop(_ info: DropInfo) -> Bool {
        !info.hasItemsConforming(to: [TrayFileDragProvider.localDragType])
            && info.hasItemsConforming(to: [UTType.fileURL])
    }
}

private enum DroppedFileURLResolver {
    static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let data = item as? Data,
           let string = String(data: data, encoding: .utf8) {
            return URL(string: string)
        }

        if let string = item as? String {
            return URL(string: string)
        }

        return nil
    }
}

private struct IslandShellShape: Shape {
    var size: CGSize
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get {
            AnimatablePair(
                AnimatablePair(size.width, size.height),
                AnimatablePair(topCornerRadius, bottomCornerRadius)
            )
        }
        set {
            size = CGSize(width: newValue.first.first, height: newValue.first.second)
            topCornerRadius = newValue.second.first
            bottomCornerRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let shellRect = CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )

        let maxRadius = min(size.width, size.height) / 2
        let topRadius = min(topCornerRadius, maxRadius)
        let bottomRadius = min(bottomCornerRadius, maxRadius)

        var path = Path()
        path.move(to: CGPoint(x: shellRect.minX + topRadius, y: shellRect.minY))
        path.addLine(to: CGPoint(x: shellRect.maxX - topRadius, y: shellRect.minY))
        if topRadius > 0 {
            path.addQuadCurve(
                to: CGPoint(x: shellRect.maxX, y: shellRect.minY + topRadius),
                control: CGPoint(x: shellRect.maxX, y: shellRect.minY)
            )
        } else {
            path.addLine(to: CGPoint(x: shellRect.maxX, y: shellRect.minY))
        }

        path.addLine(to: CGPoint(x: shellRect.maxX, y: shellRect.maxY - bottomRadius))
        if bottomRadius > 0 {
            path.addQuadCurve(
                to: CGPoint(x: shellRect.maxX - bottomRadius, y: shellRect.maxY),
                control: CGPoint(x: shellRect.maxX, y: shellRect.maxY)
            )
        } else {
            path.addLine(to: CGPoint(x: shellRect.maxX, y: shellRect.maxY))
        }

        path.addLine(to: CGPoint(x: shellRect.minX + bottomRadius, y: shellRect.maxY))
        if bottomRadius > 0 {
            path.addQuadCurve(
                to: CGPoint(x: shellRect.minX, y: shellRect.maxY - bottomRadius),
                control: CGPoint(x: shellRect.minX, y: shellRect.maxY)
            )
        } else {
            path.addLine(to: CGPoint(x: shellRect.minX, y: shellRect.maxY))
        }

        path.addLine(to: CGPoint(x: shellRect.minX, y: shellRect.minY + topRadius))
        if topRadius > 0 {
            path.addQuadCurve(
                to: CGPoint(x: shellRect.minX + topRadius, y: shellRect.minY),
                control: CGPoint(x: shellRect.minX, y: shellRect.minY)
            )
        } else {
            path.addLine(to: CGPoint(x: shellRect.minX, y: shellRect.minY))
        }
        path.closeSubpath()
        return path
    }
}

#Preview("Compact") {
    IslandView(viewModel: .preview())
        .frame(width: 520, height: 240)
        .padding()
        .background(Color.gray.opacity(0.25))
}
