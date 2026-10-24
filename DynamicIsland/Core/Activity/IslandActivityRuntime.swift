import AppKit
import Combine
import Foundation

/// One Host-owned Activity graph for the production island. Providers publish
/// data to the manager; visible actions return through the same router.
@MainActor
public final class IslandActivityRuntime {
    public let manager: ActivityManager
    public let router: ActionRouter
    public let pluginLifecycle: PluginLifecycleBridge
    public let pluginBridge: PluginJSBridge
    public let permissionManager: PermissionManager
    public let pluginScheduler: PluginScheduler
    public let pluginDiagnostics: PluginDiagnosticsStore
    let countdownDisplayClock = IslandCountdownDisplayClock()
    private var countdownDisplayObservation: UUID?
    private let pluginSchedulerEnvironment: PluginSchedulerEnvironment
    private let music: MusicActivityProvider
    private let volume: VolumeActivityProvider
    private let battery: BatteryActivityProvider?
    private weak var viewModel: IslandViewModel?
    private var toolContextObservation: AnyCancellable?

    private let musicRegistration: UUID

    public init(
        viewModel: IslandViewModel,
        batteryService: (any BatteryService)? = nil,
        batteryDebounceNanoseconds: UInt64 = BatteryActivityProvider.defaultDebounceNanoseconds
    ) {
        let manager = ActivityManager()
        let router = ActionRouter(manager: manager)
        let permissionManager = PermissionManager(decisionStore: .applicationSupport())
        let pluginScheduler = PluginScheduler(policy: .background)
        let pluginDiagnostics = PluginDiagnosticsStore()
        let pluginBridge = PluginJSBridge(storage: .applicationSupport(), permissions: permissionManager,
                                          scheduler: pluginScheduler, diagnostics: pluginDiagnostics)
        let pluginLifecycle = PluginLifecycleBridge(
            activityManager: manager,
            actionRouter: router,
            permissions: permissionManager,
            diagnostics: pluginDiagnostics,
            runtimeFactory: { PluginRuntime(package: $0, bridge: pluginBridge) }
        )
        let music = MusicActivityProvider(viewModel: viewModel, manager: manager)
        let volume = VolumeActivityProvider(viewModel: viewModel, manager: manager)
        let battery = batteryService.map {
            BatteryActivityProvider(
                service: $0,
                manager: manager,
                debounceNanoseconds: batteryDebounceNanoseconds
            )
        }

        self.manager = manager
        self.router = router
        self.pluginLifecycle = pluginLifecycle
        self.pluginBridge = pluginBridge
        self.permissionManager = permissionManager
        self.pluginScheduler = pluginScheduler
        self.pluginDiagnostics = pluginDiagnostics
        pluginSchedulerEnvironment = PluginSchedulerEnvironment(scheduler: pluginScheduler)
        self.music = music
        self.volume = volume
        self.battery = battery
        self.viewModel = viewModel
        let displayClock = countdownDisplayClock
        countdownDisplayObservation = pluginLifecycle.countdownBroker.observeChanges { [weak displayClock] in
            displayClock?.invalidate()
        }
        musicRegistration = music.registerActions(with: router)
        // Use the values delivered by the publishers: @Published emits before
        // the ViewModel's stored properties have changed. No delayed callback
        // may leave a folded or displaced tool temporarily interactive.
        toolContextObservation = Publishers.CombineLatest4(
            viewModel.$isHovering, viewModel.$isDragging,
            viewModel.$isFileTrayLocked, viewModel.$expandedSurface
        ).combineLatest(viewModel.$isTimerCompletionPresented)
            .combineLatest(viewModel.$isIslandPanelVisible)
            .sink { [weak self] completionContext, panelVisible in
                let (context, hasCompletion) = completionContext
                let (hovering, dragging, trayLocked, surface) = context
                let state = IslandViewModel.presentationState(
                    isDragging: dragging, isHovering: hovering,
                    isFileTrayLocked: trayLocked, isTimerCompletionPresented: hasCompletion
                )
                // Revoke the old surface's request before reconciling the new
                // mode. Neither @Published's old stored value nor a hidden
                // panel may grant an intermediate presentation opportunity.
                self?.manager.setPresentationRequestsAllowed(
                    state == .expanded && surface == .tools && !dragging
                        && !trayLocked && !hasCompletion && panelVisible
                )
                self?.manager.setPresentationContext(state == .compact ? .compact : .expanded)
                if state != .expanded || surface != .tools || hasCompletion {
                    self?.manager.clearToolSelection()
                }
            }
    }

    /// App teardown also removes the scheduler's system observers and deadline.
    public func shutdownPlugins() {
        viewModel?.cancelToolMenuInteraction()
        toolContextObservation?.cancel()
        toolContextObservation = nil
        manager.setPresentationRequestsAllowed(false)
        countdownDisplayClock.shutdown()
        if let countdownDisplayObservation {
            pluginLifecycle.countdownBroker.removeChangeObserver(countdownDisplayObservation)
            self.countdownDisplayObservation = nil
        }
        manager.clearToolSelection()
        pluginSchedulerEnvironment.stop()
        pluginLifecycle.shutdown()
        pluginScheduler.shutdown()
    }

    public var isCompactActivityVisible: Bool {
        manager.currentSnapshot?.activity.presentation.isCompactVisible == true
    }

    /// A user chooses the exact item captured by the Host menu. Inventory
    /// snapshots never authorize renderer actions; only currentSnapshot does.
    @discardableResult
    public func selectTool(_ snapshot: ActivitySnapshot) -> Bool {
        guard let viewModel, viewModel.presentationState == .expanded,
              !viewModel.isDragging, !viewModel.isTimerCompletionPresented else { return false }
        guard manager.selectTool(snapshot) else { return false }
        viewModel.selectExpandedSurface(.tools)
        return true
    }

    public func selectLegacySurface(_ surface: IslandExpandedSurface) {
        manager.clearToolSelection()
        viewModel?.selectExpandedSurface(surface)
    }

    public var currentActivityUsesToolLayout: Bool {
        manager.currentSnapshot?.activity.isTool == true
    }

    /// The current compact tree determines Host timer spacing. Plugin names
    /// and hidden layouts cannot opt an unrelated Activity into this geometry.
    public var currentActivityUsesCountdownCompactLayout: Bool {
        guard let presentation = manager.currentSnapshot?.activity.presentation,
              presentation.isCompactVisible else { return false }
        return !IslandRenderer.resolvedNode(in: presentation, for: .compact).countdownReferences.isEmpty
    }

    /// One content budget drives both rendering and the physical pointer region.
    /// Only the outer shell moves; the camera gap remains anchored to the screen.
    public func compactLayout(forBaseSize baseSize: CGSize) -> IslandCompactLayout {
        let hasCompactActivity = isCompactActivityVisible
        let hasNativeTimer = viewModel?.compactTimerMode != nil
            && !(prioritizesCurrentActivityOverLegacyContent && hasCompactActivity)
        if hasNativeTimer, let viewModel {
            return .nativeTimer(baseSize: baseSize, textWidth: viewModel.compactTimerTextWidth)
        }
        guard let presentation = manager.currentSnapshot?.activity.presentation,
              presentation.isCompactVisible else { return IslandCompactLayout(baseSize: baseSize) }
        return .activity(baseSize: baseSize, presentation: presentation,
                         reservesPercentageWidth: currentActivityUsesBatteryCompactLayout
                            || currentActivityUsesVolumeCompactLayout)
    }

    /// Compatibility entry point for callers that only need the visible size.
    public func compactShellSize(forBaseSize baseSize: CGSize) -> CGSize {
        compactLayout(forBaseSize: baseSize).size
    }

    /// The rendered shell and the panel's pointer region share all inputs.
    public var expandedShellSize: CGSize {
        guard let viewModel else { return IslandVisualStyle.expandedShellSize }
        return IslandVisualStyle.expandedShellSize(
            for: viewModel.expandedSurface,
            timerMode: viewModel.timerShellMode,
            hasTrayItems: !viewModel.trayItems.isEmpty,
            hasError: viewModel.lastErrorMessage != nil,
            hasTimerCompletion: viewModel.isTimerCompletionPresented,
            hasPresentedTool: currentActivityUsesToolLayout
        )
    }

    /// Only the Host-owned Battery Activity needs enough side clearance to
    /// keep both status groups outside a physical camera notch.
    public var currentActivityUsesBatteryCompactLayout: Bool {
        guard let activity = manager.currentSnapshot?.activity else { return false }
        return activity.id == BatteryActivityProvider.activityID
            && activity.source == BatteryActivityProvider.source
    }

    /// Volume keeps its glyph and widest percentage label in the two display
    /// wings while the physical notch occupies the center of the shell.
    public var currentActivityUsesVolumeCompactLayout: Bool {
        guard let activity = manager.currentSnapshot?.activity else { return false }
        return activity.id == VolumeActivityProvider.activityID
            && activity.source == VolumeActivityProvider.source
    }

    /// Transient and critical built-ins temporarily replace legacy timer or
    /// tray content. Persistent music remains tied to the selected music tab.
    public var prioritizesCurrentActivityOverLegacyContent: Bool {
        guard let snapshot = manager.currentSnapshot else { return false }
        return snapshot.activity.source != MusicActivityProvider.source
    }

    public func resolveCountdown(_ reference: IslandNode.Countdown,
                                 for snapshot: ActivitySnapshot) -> IslandCountdownDisplayValue? {
        pluginLifecycle.resolveCountdown(reference, for: snapshot)
    }

    /// Resources are resolved by the Host for the owning source. Providers do
    /// not hand filesystem paths or URLs to the renderer.
    public func resolveImage(_ image: IslandNode.ImageSource, for source: ActivitySource) -> NSImage? {
        switch source {
        case MusicActivityProvider.source:
            return music.resolveImage(image)
        default:
            return nil
        }
    }
}
