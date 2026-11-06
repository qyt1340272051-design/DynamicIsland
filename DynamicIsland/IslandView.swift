import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

public struct IslandView: View {
    @ObservedObject private var viewModel: IslandViewModel
    @ObservedObject private var activityManager: ActivityManager
    private let activityRuntime: IslandActivityRuntime
    private let requestTermination: @MainActor () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredTrayItemID: UUID?
    @State private var isQuitting = false
    @State private var isQuitImpacting = false
    @State private var isIslandFading = false
    @State private var quitAnimationTask: Task<Void, Never>?
    private var trayIconSize: CGSize { CGSize(width: e(64), height: e(64)) }

    public init(viewModel: IslandViewModel, activityRuntime: IslandActivityRuntime? = nil) {
        self.init(viewModel: viewModel, activityRuntime: activityRuntime,
                  requestTermination: { NSApp.terminate(nil) })
    }

    /// Host tests can exercise the real quit control without ending XCTest.
    init(viewModel: IslandViewModel, activityRuntime: IslandActivityRuntime? = nil,
         requestTermination: @escaping @MainActor () -> Void) {
        self.viewModel = viewModel
        let runtime = activityRuntime ?? IslandActivityRuntime(viewModel: viewModel)
        self.activityRuntime = runtime
        self.activityManager = runtime.manager
        self.requestTermination = requestTermination
    }

    public var body: some View {
        ZStack(alignment: .top) {
            islandShell
                .animation(expandedShellResizeAnimation, value: expandedShellSize)
            islandBody
                .frame(width: viewModel.displayLayout.panelSize.width, height: contentSize.height, alignment: .top)
                .mask(alignment: .top) {
                    shellShape
                        .frame(width: maximumShellSize.width, height: maximumShellSize.height)
                        .offset(x: shellHorizontalOffset)
                        .animation(expandedShellResizeAnimation, value: expandedShellSize)
                }
        }
        .frame(width: viewModel.displayLayout.panelSize.width, height: viewModel.displayLayout.panelSize.height, alignment: .top)
        .clipped()
        .environment(\.islandLayoutScale, displayLayoutScale)
        .opacity(isIslandFading ? 0 : 1)
        .animation(reduceMotion ? nil : IslandQuitAnimation.islandFade, value: isIslandFading)
        .animation(IslandExpansionAnimation.shell, value: isExpanded)
        .animation(reduceMotion ? nil : IslandExpansionAnimation.compactActivityShell, value: hasCompactActivity)
        .animation(reduceMotion ? nil : IslandExpansionAnimation.compactActivityShell, value: compactPresentationSize)
        .animation(reduceMotion ? nil : IslandExpansionAnimation.compactActivityShell, value: viewModel.compactTimerMode)
        .animation(IslandExpansionAnimation.pointerHover, value: viewModel.isPointerInside)
        .onDrop(
            of: [UTType.fileURL, TrayFileDragProvider.localDragType],
            delegate: IslandFileDropDelegate(viewModel: viewModel)
        )
        .allowsHitTesting(!isQuitting)
        .onReceive(NotificationCenter.default.publisher(for: .islandQuitCancelled)) { _ in
            restoreAfterCancelledQuit()
        }
    }

    private var shellSize: CGSize {
        if isExpanded {
            return expandedShellSize
        }

        let compactSize = compactPresentationSize
        guard viewModel.isPointerInside else {
            return compactSize
        }

        return CGSize(
            width: min(
                compactSize.width * IslandExpansionAnimation.pointerHoverScale,
                IslandPanelHoverRegion.compactHoverMaximumWidth(
                    panelWidth: viewModel.displayLayout.panelSize.width,
                    expandedShellWidth: max(compactSize.width, expandedShellSize.width),
                    centerOffset: p(compactLayout.centerOffset))
            ),
            height: compactSize.height * IslandExpansionAnimation.pointerHoverScale
        )
    }

    private var displayLayoutScale: CGFloat { viewModel.displayLayout.scale }

    private var expandedLayoutScale: CGFloat { viewModel.displayLayout.expandedScale }

    private func p(_ designPoints: CGFloat) -> CGFloat { designPoints * displayLayoutScale }

    private func e(_ designPoints: CGFloat) -> CGFloat { designPoints * expandedLayoutScale }

    private var maximumShellSize: CGSize { viewModel.displayLayout.scaled(IslandVisualStyle.expandedShellSize) }

    private var contentSize: CGSize { viewModel.displayLayout.scaledExpanded(IslandVisualStyle.expandedContentSize) }

    private var expandedShellSize: CGSize { viewModel.displayLayout.scaledExpanded(activityRuntime.expandedShellSize) }

    private var compactLayout: IslandCompactLayout {
        activityRuntime.compactLayout(forBaseSize: viewModel.displayLayout.designCompactSize)
    }

    private var expandedShellResizeAnimation: Animation? {
        guard !reduceMotion else { return nil }
        guard isExpanded, viewModel.expandedSurface == .tools else {
            return IslandExpansionAnimation.shell
        }

        // Timer content fades out before a shorter shell closes; a taller shell opens first.
        return expandedShellSize.height <= e(IslandVisualStyle.expandedCompactContentHeight)
            ? IslandTimerModeTransition.shellShrink
            : IslandTimerModeTransition.shellGrowth
    }

    private var compactPresentationSize: CGSize {
        viewModel.displayLayout.scaled(compactLayout.size)
    }

    private var hasCompactContent: Bool {
        viewModel.compactTimerMode != nil || hasCompactActivity
    }

    private var hasCompactActivity: Bool {
        activityRuntime.isCompactActivityVisible
    }

    private var shellHorizontalOffset: CGFloat {
        isExpanded ? 0 : p(compactLayout.centerOffset)
    }

    private var shellCornerRadii: (top: CGFloat, bottom: CGFloat) {
        isExpanded
            ? (e(IslandVisualStyle.expandedShellCornerRadius), e(IslandVisualStyle.expandedShellCornerRadius))
            : (0, shellSize.height / 2)
    }

    private var shellShape: IslandShellShape {
        IslandShellShape(size: shellSize, topCornerRadius: shellCornerRadii.top, bottomCornerRadius: shellCornerRadii.bottom)
    }

    private var isExpanded: Bool {
        isQuitting || viewModel.presentationState != .compact
    }

    private var isCompactHovering: Bool {
        !isExpanded && viewModel.isPointerInside
    }

    private var islandShell: some View {
        islandBackground
            .frame(width: maximumShellSize.width, height: maximumShellSize.height)
            .offset(x: shellHorizontalOffset)
            .shadow(
                color: .black.opacity(IslandVisualStyle.shellShadowOpacity(isCompactHovering: isCompactHovering)),
                radius: p(IslandVisualStyle.hoverShellShadowRadius),
                y: p(IslandVisualStyle.hoverShellShadowYOffset)
            )
    }

    private var islandBackground: some View {
        shellShape
            .fill(Color.black)
            .overlay {
                if viewModel.isDragging {
                    shellShape
                        .stroke(Color.accentColor.opacity(IslandVisualStyle.draggingShellStrokeOpacity), lineWidth: p(1))
                } else if isExpanded, IslandVisualStyle.expandedShellStrokeOpacity > 0 {
                    shellShape
                        .stroke(Color.white.opacity(IslandVisualStyle.expandedShellStrokeOpacity), lineWidth: p(1))
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
                .offset(x: p(compactLayout.centerOffset))
                .allowsHitTesting(!isExpanded)

            expandedContent
                .frame(width: contentSize.width, height: expandedShellSize.height, alignment: .top)
                .opacity(isExpanded ? 1 : 0)
                .allowsHitTesting(isExpanded)
        }
        .animation(isExpanded ? IslandExpansionAnimation.contentReveal : IslandExpansionAnimation.contentDismiss, value: isExpanded)
    }

    @ViewBuilder
    private var compactContent: some View {
        if let fallback = compactLayout.fallbackMinimalNode {
            let region = CGSize(width: p(compactLayout.trailingWidth), height: compactPresentationSize.height)
            IslandRenderer(
                presentation: ActivityPresentation(title: "Activity", minimal: fallback),
                mode: .minimal, shellSize: region
            )
            .frame(width: region.width, height: region.height)
            .frame(width: compactPresentationSize.width, height: compactPresentationSize.height, alignment: .trailing)
        } else if activityRuntime.prioritizesCurrentActivityOverLegacyContent,
           let snapshot = activityManager.currentSnapshot,
           snapshot.activity.presentation.isCompactVisible {
            renderedCollapsedActivity(snapshot)
                .transition(compactContentTransition)
        } else if viewModel.compactTimerMode != nil {
            CompactTimerStatus(textWidth: viewModel.compactTimerTextWidth, model: viewModel.timerTools)
                .transition(compactContentTransition)
        } else if hasCompactActivity, let snapshot = activityManager.currentSnapshot {
            renderedCollapsedActivity(snapshot)
                .transition(compactContentTransition)
        }
    }

    private var compactContentTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .scale(scale: IslandExpansionAnimation.compactActivityContentScale))
    }

    private func renderedCollapsedActivity(_ snapshot: ActivitySnapshot) -> some View {
        let mode: ActivityPresentation.Mode = compactLayout.usesMinimalPresentation
            ? .minimal : snapshot.activity.presentation.effectiveCollapsedMode
        let region = mode == .minimal
            ? CGSize(width: p(compactLayout.trailingWidth), height: compactPresentationSize.height)
            : compactPresentationSize
        return renderedActivity(snapshot, mode: mode, shellSize: region)
            .frame(width: region.width, height: region.height)
            .frame(width: compactPresentationSize.width, height: compactPresentationSize.height,
                   alignment: .trailing)
            .animation(reduceMotion ? nil : IslandExpansionAnimation.compactActivityShell, value: mode)
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(spacing: e(IslandVisualStyle.expandedSurfaceSpacing)) {
            surfaceSwitcher
                .frame(height: e(IslandVisualStyle.expandedSurfaceSwitcherHeight))

            ZStack(alignment: .topLeading) {
                expandedSurfaceContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .animation(IslandSurfaceTransition.animation, value: viewModel.expandedSurface)
        }
        .padding(e(IslandVisualStyle.expandedContentPadding))
        .foregroundStyle(.white)
        .environment(\.islandLayoutScale, expandedLayoutScale)
    }

    @ViewBuilder
    private var expandedSurfaceContent: some View {
        Group {
            if activityRuntime.prioritizesCurrentActivityOverLegacyContent,
               let snapshot = activityManager.currentSnapshot {
                renderedActivity(
                    snapshot,
                    mode: .expanded,
                    shellSize: CGSize(width: contentSize.width, height: expandedShellSize.height)
                )
            } else {
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
        }
        .id(expandedContentIdentity)
        .transition(IslandSurfaceTransition.content)
    }

    private var expandedContentIdentity: String {
        if activityRuntime.prioritizesCurrentActivityOverLegacyContent,
           let id = activityManager.currentSnapshot?.activity.id {
            return "activity:\(id)"
        }
        switch viewModel.expandedSurface {
        case .music: return "surface:music"
        case .fileTray: return "surface:fileTray"
        case .tools: return "surface:tools"
        }
    }

    private var surfaceSwitcher: some View {
        HStack(spacing: e(8)) {
            surfaceButton(surface: .music, title: "音乐", systemName: "music.note")
                .accessibilityIdentifier("island-surface-music")
            surfaceButton(surface: .fileTray, title: "拖盘", systemName: "tray.full")
                .accessibilityIdentifier("island-surface-tray")
            toolsSurfaceSelector
            Spacer(minLength: 0)
            quitButton
        }
    }

    @ViewBuilder
    private var toolsSurfaceSelector: some View {
        if activityManager.toolSnapshots.isEmpty {
            surfaceButton(surface: .tools, title: "计时", systemName: "alarm.fill")
                .accessibilityIdentifier("island-surface-tools")
        } else {
            let isSelected = viewModel.expandedSurface == .tools
            IslandToolMenu(
                entries: [
                    .init(id: "island-tool-native", title: "内置计时", symbolName: "alarm.fill") {
                        activityRuntime.selectLegacySurface(.tools)
                    }
                ] + activityManager.toolSnapshots.map { snapshot in
                    .init(id: "island-tool-\(snapshot.activity.id)",
                          title: snapshot.activity.presentation.title,
                          symbolName: snapshot.activity.presentation.symbolName ?? "puzzlepiece.extension") {
                        _ = activityRuntime.selectTool(snapshot)
                    }
                },
                isSelected: isSelected,
                isEnabled: viewModel.isIslandPanelVisible && !viewModel.isDragging
                    && !viewModel.isTimerCompletionPresented,
                onTrackingBegan: viewModel.beginToolMenuInteraction,
                onTrackingEnded: viewModel.endToolMenuInteraction,
                onTrackingCancelled: viewModel.cancelToolMenuInteraction,
                onSessionIsCurrent: viewModel.isToolMenuInteractionCurrent
            )
            .frame(width: e(28), height: e(28))
        }
    }

    private var quitButton: some View {
        Button {
            guard !isQuitting else { return }
            isQuitting = true
            if reduceMotion {
                requestTermination()
                return
            }

            isQuitImpacting = true
            quitAnimationTask = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: IslandQuitAnimation.impactHoldNanoseconds)
                    guard !Task.isCancelled else { return }
                    isQuitImpacting = false
                    try await Task.sleep(nanoseconds: IslandQuitAnimation.reboundWaitNanoseconds)
                    guard !Task.isCancelled else { return }
                    isIslandFading = true
                    try await Task.sleep(nanoseconds: IslandQuitAnimation.fadeWaitNanoseconds)
                    guard !Task.isCancelled else { return }
                    quitAnimationTask = nil
                    requestTermination()
                } catch {
                    return
                }
            }
        } label: {
            Image(systemName: "power")
                .font(.system(size: e(12), weight: .semibold))
                .foregroundStyle(isQuitImpacting ? Color.red : Color.white.opacity(0.68))
                .scaleEffect(isQuitImpacting ? IslandQuitAnimation.pressedScale : 1)
                .frame(width: e(28), height: e(28))
                .background(isQuitImpacting ? Color.red.opacity(0.28) : Color.white.opacity(0.08), in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.red.opacity(isQuitImpacting ? 0.9 : 0), lineWidth: e(1.5))
                }
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!isQuitting)
        .animation(reduceMotion ? nil : IslandQuitAnimation.impact, value: isQuitImpacting)
        .help("退出 Dynamic Island")
        .accessibilityLabel("退出 Dynamic Island")
    }

    private func restoreAfterCancelledQuit() {
        guard isQuitting else { return }
        quitAnimationTask?.cancel()
        quitAnimationTask = nil
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isQuitting = false
            isQuitImpacting = false
            isIslandFading = false
        }
    }

    private var musicExpandedContent: some View {
        Group {
            if let snapshot = activityManager.currentSnapshot {
                renderedActivity(
                    snapshot,
                    mode: .expanded,
                    shellSize: CGSize(width: contentSize.width, height: expandedShellSize.height)
                )
            } else {
                Text("在 Apple Music 播放后显示曲目信息")
                    .font(IslandDesignTokens.font(for: .body, scale: expandedLayoutScale))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func route(_ action: IslandRenderAction, from snapshot: ActivitySnapshot) {
        _ = activityRuntime.router.dispatch(
            id: snapshot.activity.id,
            source: snapshot.activity.source,
            instanceToken: snapshot.instanceToken,
            action: action
        )
    }

    private func renderedActivity(
        _ snapshot: ActivitySnapshot,
        mode: ActivityPresentation.Mode,
        shellSize: CGSize
    ) -> some View {
        IslandRenderer(
            presentation: snapshot.activity.presentation,
            mode: mode,
            shellSize: shellSize,
            imageResolver: { image in
                activityRuntime.resolveImage(image, for: snapshot.activity.source)
            },
            countdownResolver: { reference in
                activityRuntime.resolveCountdown(reference, for: snapshot)
            },
            isVisible: viewModel.isIslandPanelVisible && !isQuitting && (mode == .expanded ? isExpanded : !isExpanded),
            displayClock: activityRuntime.countdownDisplayClock,
            onAction: { action in route(action, from: snapshot) }
        )
        .id(snapshot.instanceToken)
    }

    private var fileTrayExpandedContent: some View {
        VStack(spacing: e(6)) {
            trayArea
            Spacer(minLength: 0)

            if let message = viewModel.lastErrorMessage {
                Text(message)
                    .font(IslandDesignTokens.font(for: .caption, scale: expandedLayoutScale))
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var trayArea: some View {
        VStack(spacing: e(4)) {
            HStack {
                Label(viewModel.isDragging ? "松开以加入文件托盘" : "文件托盘", systemImage: "tray.full")
                    .font(.system(size: e(13), weight: .semibold))
                Spacer()
                if !viewModel.trayItems.isEmpty {
                    Button(action: viewModel.shareTrayViaAirDrop) {
                        Label("AirDrop", systemImage: "square.and.arrow.up")
                            .font(.system(size: e(11)))
                    }
                    .transition(.opacity)
                }
                TrayDeleteButton(hasItems: !viewModel.trayItems.isEmpty, action: viewModel.clearTray)
                Button(action: viewModel.toggleFileTrayLock) {
                    Image(systemName: viewModel.isFileTrayLocked ? "lock.fill" : "lock.open")
                        .font(.system(size: e(12), weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: e(24), height: e(24))
                        .background(Color.white.opacity(viewModel.isFileTrayLocked ? 0.18 : 0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(viewModel.isFileTrayLocked ? .white : .white.opacity(0.68))
                .animation(IslandFileTrayAnimation.lock, value: viewModel.isFileTrayLocked)
                .help(viewModel.isFileTrayLocked ? "解锁文件托盘" : "锁定文件托盘")
                .accessibilityLabel(viewModel.isFileTrayLocked ? "解锁文件托盘" : "锁定文件托盘")
            }

            if viewModel.trayItems.isEmpty {
                RoundedRectangle(cornerRadius: e(10), style: .continuous)
                    .fill(Color.white.opacity(viewModel.isDragging ? 0.14 : 0.07))
                    .frame(height: e(48))
                    .overlay {
                        Text("拖入文件后可暂存并通过 AirDrop 分享")
                            .font(IslandDesignTokens.font(for: .body, scale: expandedLayoutScale))
                            .foregroundStyle(.white.opacity(0.58))
                    }
                    .transition(.opacity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: e(12)) {
                        ForEach(viewModel.trayItems) { item in
                            trayIcon(for: item)
                                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        }
                    }
                    .padding(.vertical, e(2))
                }
                .frame(height: trayIconSize.height + e(4))
                .transition(.opacity)
            }
        }
        .animation(IslandFileTrayAnimation.fileFade, value: viewModel.trayItems.map(\.id))
    }

    private func trayIcon(for item: TrayFileItem) -> some View {
        VStack(spacing: e(3)) {
            ZStack(alignment: .bottomTrailing) {
                trayIconArtwork(for: item)

                if !item.formattedSize.isEmpty {
                    Text(item.formattedSize)
                        .font(.system(size: e(8), weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, e(4))
                        .padding(.vertical, e(2))
                        .background(Color.black.opacity(0.62), in: Capsule())
                        .offset(x: e(7), y: e(2))
                }
            }

            Text(item.displayName)
                .font(.system(size: e(10), weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(width: trayIconSize.width)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: e(28), alignment: .top)
        }
        .frame(width: trayIconSize.width, height: trayIconSize.height, alignment: .top)
        .contentShape(Rectangle())
        .help(item.displayName)
        .onDrag {
            TrayFileDragProvider.itemProvider(for: item)
        }
        .overlay(alignment: .topLeading) {
            if hoveredTrayItemID == item.id {
                Button {
                    viewModel.removeTrayItem(item)
                    hoveredTrayItemID = nil
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: e(11), weight: .heavy))
                        .foregroundStyle(.red)
                        .frame(width: e(22), height: e(22))
                        .background(Color.black.opacity(0.88), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.leading, e(9))
                .help("移除 \(item.displayName)")
                .accessibilityLabel("移除 \(item.displayName)")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .onHover { hovering in
            if hovering {
                hoveredTrayItemID = item.id
            } else if hoveredTrayItemID == item.id {
                hoveredTrayItemID = nil
            }
        }
        .animation(.easeInOut(duration: 0.15), value: hoveredTrayItemID == item.id)
        .accessibilityAction(named: Text("移除 \(item.displayName)")) {
            viewModel.removeTrayItem(item)
        }
    }

    @ViewBuilder
    private func trayIconArtwork(for item: TrayFileItem) -> some View {
        switch TrayFileIconKind.kind(for: item) {
        case .imageThumbnail:
            if let image = NSImage(contentsOf: item.url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: e(40), height: e(32))
                    .clipShape(RoundedRectangle(cornerRadius: e(6), style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: e(6), style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: e(0.5))
                    }
            } else {
                finderIcon(for: item)
            }
        case .systemIcon:
            finderIcon(for: item)
        }
    }

    private func surfaceButton(surface: IslandExpandedSurface, title: String, systemName: String) -> some View {
        let isSelected = viewModel.expandedSurface == surface
        return Button {
            activityRuntime.selectLegacySurface(surface)
        } label: {
            surfaceIcon(surface: surface, systemName: systemName)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .white : .white.opacity(0.68))
        .animation(reduceMotion ? nil : IslandSurfaceTransition.animation, value: isSelected)
        .help(title)
        .accessibilityLabel(title)
    }

    private func surfaceIcon(surface: IslandExpandedSurface, systemName: String) -> some View {
        let isSelected = viewModel.expandedSurface == surface
        return Image(systemName: systemName)
            .font(.system(size: e(12), weight: .semibold))
            .frame(width: e(28), height: e(28))
            .background(Color.white.opacity(isSelected ? 0.18 : 0.08), in: Circle())
            .overlay {
                Circle()
                    .stroke(Color.white.opacity(isSelected ? 0.22 : 0.08), lineWidth: e(0.5))
            }
    }

    private func finderIcon(for item: TrayFileItem) -> some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
            .resizable()
            .scaledToFit()
            .frame(width: e(36), height: e(32))
    }
}

private struct TrayDeleteButton: View {
    @Environment(\.islandLayoutScale) private var displayLayoutScale
    private func p(_ value: CGFloat) -> CGFloat { value * displayLayoutScale }
    let hasItems: Bool
    let action: () -> Void

    @State private var impactCount = 0
    @State private var holdsImpact = false
    @State private var impactTask: Task<Void, Never>?

    var body: some View {
        Button {
            impactTask?.cancel()
            holdsImpact = true
            impactCount += 1
            action()
            impactTask = Task {
                try? await Task.sleep(nanoseconds: IslandFileTrayAnimation.impactHoldNanoseconds)
                guard !Task.isCancelled else { return }
                holdsImpact = false
                impactTask = nil
            }
        } label: {
            Image(systemName: "trash")
                .font(.system(size: p(12), weight: .semibold))
                .foregroundStyle(holdsImpact ? Color.red : Color.white.opacity(0.78))
                .symbolEffect(.bounce, value: impactCount)
                .frame(width: p(24), height: p(24))
                .background(Color.red.opacity(holdsImpact ? 0.22 : 0), in: Circle())
                .animation(IslandFileTrayAnimation.impact, value: holdsImpact)
        }
        .buttonStyle(TrayDeleteImpactButtonStyle())
        .opacity(hasItems || holdsImpact ? 1 : 0)
        .disabled(!hasItems)
        .accessibilityHidden(!hasItems)
        .animation(IslandFileTrayAnimation.fileFade, value: hasItems || holdsImpact)
        .help("清空文件托盘")
        .accessibilityLabel("清空文件托盘")
    }
}

private struct TrayDeleteImpactButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.78 : 1)
            .animation(IslandFileTrayAnimation.impact, value: configuration.isPressed)
    }
}

private struct CompactTimerStatus: View {
    @Environment(\.islandLayoutScale) private var displayLayoutScale
    private func p(_ value: CGFloat) -> CGFloat { value * displayLayoutScale }
    let textWidth: CGFloat
    @ObservedObject var model: IslandTimerToolsModel

    var body: some View {
        if let mode = model.sessionMode {
            HStack(spacing: p(0)) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: p(11), weight: .semibold))
                    .foregroundStyle(tint(for: mode))
                    .frame(width: p(26), height: p(26))
                    .background(tint(for: mode).opacity(0.14), in: Circle())

                Spacer(minLength: 0)

                Text(model.compactTimeText)
                    .font(.system(size: p(11), weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .frame(width: p(textWidth), alignment: .trailing)
            }
            .padding(.horizontal, p(8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(mode.title)，\(model.compactTimeText)")
        }
    }

    private func tint(for mode: IslandTimerToolMode) -> Color {
        switch mode {
        case .stopwatch:
            return .cyan
        case .countdown:
            return .orange
        }
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

struct IslandShellShape: Shape {
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
            y: rect.minY,
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
