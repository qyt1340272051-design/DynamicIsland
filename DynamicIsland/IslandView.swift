import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct IslandView: View {
    @ObservedObject private var viewModel: IslandViewModel
    @ObservedObject private var activityManager: ActivityManager
    private let activityRuntime: IslandActivityRuntime
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredTrayItemID: UUID?
    @State private var isQuitting = false
    @State private var isQuitImpacting = false
    @State private var isIslandFading = false
    private static let trayIconSize = CGSize(width: 74, height: 74)

    public init(viewModel: IslandViewModel, activityRuntime: IslandActivityRuntime? = nil) {
        self.viewModel = viewModel
        let runtime = activityRuntime ?? IslandActivityRuntime(viewModel: viewModel)
        self.activityRuntime = runtime
        self.activityManager = runtime.manager
    }

    public var body: some View {
        ZStack(alignment: .top) {
            islandShell
                .animation(expandedShellResizeAnimation, value: expandedShellSize)
            islandBody
                .frame(width: contentSize.width, height: contentSize.height)
                .clipShape(RoundedRectangle(cornerRadius: contentClipCornerRadius, style: .continuous))
                .mask(alignment: .top) {
                    shellShape
                        .frame(width: IslandVisualStyle.expandedShellSize.width, height: IslandVisualStyle.expandedShellSize.height)
                        .offset(y: shellVerticalOffset)
                        .animation(expandedShellResizeAnimation, value: expandedShellSize)
                }
        }
        .compositingGroup()
        .frame(width: IslandPanelGeometry.expandedSize.width, height: IslandPanelGeometry.expandedSize.height, alignment: .top)
        .clipped()
        .opacity(isIslandFading ? 0 : 1)
        .animation(reduceMotion ? nil : IslandQuitAnimation.islandFade, value: isIslandFading)
        .animation(IslandExpansionAnimation.shell, value: isExpanded)
        .animation(reduceMotion ? nil : IslandExpansionAnimation.compactActivityShell, value: hasCompactActivity)
        .animation(reduceMotion ? nil : IslandExpansionAnimation.compactActivityShell, value: compactActivityLayout)
        .animation(reduceMotion ? nil : IslandExpansionAnimation.compactActivityShell, value: viewModel.compactTimerMode)
        .animation(IslandExpansionAnimation.pointerHover, value: viewModel.isPointerInside)
        .onDrop(
            of: [UTType.fileURL, TrayFileDragProvider.localDragType],
            delegate: IslandFileDropDelegate(viewModel: viewModel)
        )
        .allowsHitTesting(!isQuitting)
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
                IslandVisualStyle.expandedShellSize.width
            ),
            height: compactSize.height * IslandExpansionAnimation.pointerHoverScale
        )
    }

    private var contentSize: CGSize {
        IslandVisualStyle.expandedContentSize
    }

    private var expandedShellSize: CGSize {
        activityRuntime.expandedShellSize
    }

    private var expandedShellResizeAnimation: Animation? {
        guard !reduceMotion else { return nil }
        guard isExpanded, viewModel.expandedSurface == .tools else {
            return IslandExpansionAnimation.shell
        }

        // Timer content fades out before a shorter shell closes; a taller shell opens first.
        return expandedShellSize.height <= IslandVisualStyle.expandedCompactContentHeight
            ? IslandTimerModeTransition.shellShrink
            : IslandTimerModeTransition.shellGrowth
    }

    private var compactPresentationSize: CGSize {
        IslandVisualStyle.compactShellSize(
            baseSize: viewModel.compactPanelSize,
            hasCompactActivity: hasCompactActivity,
            hasActiveTimer: viewModel.compactTimerMode != nil
                && !(activityRuntime.prioritizesCurrentActivityOverLegacyContent
                    && hasCompactActivity),
            activityLayout: compactActivityLayout
        )
    }

    private var compactActivityLayout: IslandVisualStyle.CompactActivityLayout {
        if activityRuntime.currentActivityUsesBatteryCompactLayout {
            return .battery
        }
        if activityRuntime.currentActivityUsesVolumeCompactLayout {
            return .volume
        }
        return .standard
    }

    private var hasCompactContent: Bool {
        viewModel.compactTimerMode != nil || hasCompactActivity
    }

    private var hasCompactActivity: Bool {
        activityRuntime.isCompactActivityVisible
    }

    private var shellVerticalOffset: CGFloat {
        -(IslandVisualStyle.expandedShellSize.height - shellSize.height) / 2
    }

    private var shellCornerRadii: (top: CGFloat, bottom: CGFloat) {
        IslandVisualStyle.shellCornerRadii(isExpanded: isExpanded, shellHeight: shellSize.height)
    }

    private var shellShape: IslandShellShape {
        IslandShellShape(size: shellSize, topCornerRadius: shellCornerRadii.top, bottomCornerRadius: shellCornerRadii.bottom)
    }

    private var contentClipCornerRadius: CGFloat {
        isExpanded ? IslandVisualStyle.expandedShellCornerRadius : shellCornerRadii.bottom
    }

    private var isExpanded: Bool {
        isQuitting || viewModel.presentationState != .compact
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
        shellShape
            .fill(Color.black)
            .overlay {
                if viewModel.isDragging {
                    shellShape
                        .stroke(Color.accentColor.opacity(IslandVisualStyle.draggingShellStrokeOpacity), lineWidth: 1)
                } else if isExpanded, IslandVisualStyle.expandedShellStrokeOpacity > 0 {
                    shellShape
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
                .frame(width: contentSize.width, height: contentSize.height)
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
        if activityRuntime.prioritizesCurrentActivityOverLegacyContent,
           let snapshot = activityManager.currentSnapshot,
           snapshot.activity.presentation.isCompactVisible {
            renderedActivity(snapshot, mode: .compact, shellSize: compactPresentationSize)
                .transition(compactContentTransition)
        } else if viewModel.compactTimerMode != nil {
            CompactTimerStatus(model: viewModel.timerTools)
                .transition(compactContentTransition)
        } else if hasCompactActivity, let snapshot = activityManager.currentSnapshot {
            renderedActivity(snapshot, mode: .compact, shellSize: compactPresentationSize)
                .transition(compactContentTransition)
        }
    }

    private var compactContentTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .scale(scale: IslandExpansionAnimation.compactActivityContentScale))
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(spacing: IslandVisualStyle.expandedSurfaceSpacing) {
            surfaceSwitcher
                .frame(height: IslandVisualStyle.expandedSurfaceSwitcherHeight)

            ZStack(alignment: .topLeading) {
                expandedSurfaceContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .animation(IslandSurfaceTransition.animation, value: viewModel.expandedSurface)
        }
        .padding(IslandVisualStyle.expandedContentPadding)
        .foregroundStyle(.white)
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
        HStack(spacing: 8) {
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
            Menu {
                Button {
                    activityRuntime.selectLegacySurface(.tools)
                } label: {
                    Label("内置计时", systemImage: "alarm.fill")
                }
                .accessibilityIdentifier("island-tool-native")
                Divider()
                ForEach(activityManager.toolSnapshots, id: \.activity.id) { snapshot in
                    Button {
                        _ = activityRuntime.selectTool(snapshot)
                    } label: {
                        Label(snapshot.activity.presentation.title,
                              systemImage: snapshot.activity.presentation.symbolName ?? "puzzlepiece.extension")
                    }
                    .accessibilityIdentifier("island-tool-\(snapshot.activity.id)")
                }
            } label: {
                surfaceIcon(surface: .tools, systemName: "alarm.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .foregroundStyle(isSelected ? .white : .white.opacity(0.68))
            .animation(reduceMotion ? nil : IslandSurfaceTransition.animation, value: isSelected)
            .help("计时与插件工具")
            .accessibilityLabel("计时")
            .accessibilityIdentifier("island-tool-selector")
        }
    }

    private var quitButton: some View {
        Button {
            guard !isQuitting else { return }
            isQuitting = true
            if reduceMotion {
                NSApp.terminate(nil)
                return
            }

            isQuitImpacting = true
            Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: IslandQuitAnimation.impactHoldNanoseconds)
                    isQuitImpacting = false
                    try await Task.sleep(nanoseconds: IslandQuitAnimation.reboundWaitNanoseconds)
                    isIslandFading = true
                    try await Task.sleep(nanoseconds: IslandQuitAnimation.fadeWaitNanoseconds)
                    NSApp.terminate(nil)
                } catch {
                    return
                }
            }
        } label: {
            Image(systemName: "power")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isQuitImpacting ? Color.red : Color.white.opacity(0.68))
                .scaleEffect(isQuitImpacting ? IslandQuitAnimation.pressedScale : 1)
                .frame(width: 28, height: 28)
                .background(isQuitImpacting ? Color.red.opacity(0.28) : Color.white.opacity(0.08), in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.red.opacity(isQuitImpacting ? 0.9 : 0), lineWidth: 1.5)
                }
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!isQuitting)
        .animation(reduceMotion ? nil : IslandQuitAnimation.impact, value: isQuitImpacting)
        .help("退出 Dynamic Island")
        .accessibilityLabel("退出 Dynamic Island")
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
                    .font(.caption)
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
            onAction: { action in route(action, from: snapshot) }
        )
        .id(snapshot.instanceToken)
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
                    .transition(.opacity)
                }
                TrayDeleteButton(hasItems: !viewModel.trayItems.isEmpty, action: viewModel.clearTray)
                Button(action: viewModel.toggleFileTrayLock) {
                    Image(systemName: viewModel.isFileTrayLocked ? "lock.fill" : "lock.open")
                        .font(.system(size: 12, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(viewModel.isFileTrayLocked ? 0.18 : 0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(viewModel.isFileTrayLocked ? .white : .white.opacity(0.68))
                .animation(IslandFileTrayAnimation.lock, value: viewModel.isFileTrayLocked)
                .help(viewModel.isFileTrayLocked ? "解锁文件托盘" : "锁定文件托盘")
                .accessibilityLabel(viewModel.isFileTrayLocked ? "解锁文件托盘" : "锁定文件托盘")
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
                    .transition(.opacity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(viewModel.trayItems) { item in
                            trayIcon(for: item)
                                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: Self.trayIconSize.height + 6)
                .transition(.opacity)
            }
        }
        .animation(IslandFileTrayAnimation.fileFade, value: viewModel.trayItems.map(\.id))
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
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.red)
                        .frame(width: 22, height: 22)
                        .background(Color.black.opacity(0.88), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 9)
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
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 28, height: 28)
            .background(Color.white.opacity(isSelected ? 0.18 : 0.08), in: Circle())
            .overlay {
                Circle()
                    .stroke(Color.white.opacity(isSelected ? 0.22 : 0.08), lineWidth: 0.5)
            }
    }

    private func finderIcon(for item: TrayFileItem) -> some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
            .resizable()
            .scaledToFit()
            .frame(width: 44, height: 42)
    }
}

private struct TrayDeleteButton: View {
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(holdsImpact ? Color.red : Color.white.opacity(0.78))
                .symbolEffect(.bounce, value: impactCount)
                .frame(width: 28, height: 28)
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
