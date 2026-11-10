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
    public let toolPlacements: PluginToolPlacementStore
    let countdownDisplayClock = IslandCountdownDisplayClock()
    let compactCountdownLayout = IslandCompactCountdownLayout()
    private var compactCountdownObservation: AnyCancellable?
    private var compactCountdownSnapshotObservation: AnyCancellable?
    private var compactCountdownRefreshTask: Task<Void, Never>?
    private var countdownDisplayObservation: UUID?
    private let pluginSchedulerEnvironment: PluginSchedulerEnvironment
    private let music: MusicActivityProvider
    private let volume: VolumeActivityProvider
    private let calendar: CalendarActivityProvider
    private let battery: BatteryActivityProvider?
    private weak var viewModel: IslandViewModel?
    private var toolContextObservation: AnyCancellable?
    private var toolPlacementObservation: AnyCancellable?
    private var toolPlacementAssignments: [String: PluginToolArea]
    private var toolContext: ToolContext?
    private var visibleToolArea: PluginToolArea?
    private var toolForUserExpansion: ActivitySnapshot?

    private struct ToolContext {
        let state: IslandPresentationState
        let surface: IslandExpandedSurface
        let isAvailable: Bool

        var area: PluginToolArea? {
            guard isAvailable else { return nil }
            switch surface {
            case .tools: return .timer
            case .utilities: return .tools
            case .music, .fileTray: return nil
            }
        }
    }

    private let musicRegistration: UUID

    public init(
        viewModel: IslandViewModel,
        musicProviders: OptionalMusicProviderRegistry? = nil,
        batteryService: (any BatteryService)? = nil,
        batteryDebounceNanoseconds: UInt64 = BatteryActivityProvider.defaultDebounceNanoseconds,
        toolPlacements: PluginToolPlacementStore? = nil
    ) {
        let toolPlacements = toolPlacements ?? PluginToolPlacementStore()
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
            musicProviders: musicProviders,
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
        self.toolPlacements = toolPlacements
        toolPlacementAssignments = toolPlacements.placements
        pluginSchedulerEnvironment = PluginSchedulerEnvironment(scheduler: pluginScheduler)
        self.music = music
        self.volume = volume
        self.calendar = CalendarActivityProvider(model: viewModel.calendarAgenda, manager: manager)
        self.battery = battery
        self.viewModel = viewModel
        let displayClock = countdownDisplayClock
        countdownDisplayObservation = pluginLifecycle.countdownBroker.observeChanges { [weak displayClock] in
            displayClock?.invalidate()
        }
        musicRegistration = music.registerActions(with: router)
        viewModel.activitySurfaceForExpansion = { [weak self] in
            guard let self else { return nil }
            self.toolForUserExpansion = nil
            guard let model = self.viewModel, model.isIslandPanelVisible,
                  !model.isTimerCompletionPresented else { return nil }
            guard let snapshot = self.manager.currentSnapshot,
                  snapshot.activity.isTool, snapshot.activity.presentation.isCompactVisible else { return nil }
            self.toolForUserExpansion = snapshot
            return self.toolArea(for: snapshot.activity.source) == .timer ? .tools : .utilities
        }
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
                self?.updateToolContext(.init(
                    state: state, surface: surface,
                    isAvailable: state == .expanded && !dragging && !trayLocked
                        && !hasCompletion && panelVisible
                ))
            }
        toolPlacementObservation = toolPlacements.$placements.dropFirst().sink { [weak self] placements in
            self?.updateToolPlacements(placements)
        }
        compactCountdownObservation = countdownDisplayClock.$revision.dropFirst().sink { [weak self] _ in
            self?.refreshCompactCountdownWidths()
        }
        compactCountdownSnapshotObservation = manager.$currentSnapshot.sink { [weak self] snapshot in
            guard let self else { return }
            self.compactCountdownRefreshTask?.cancel()
            // resolveCountdown checks the committed current instance. Published
            // emits before storage, so resolve only after this setter returns.
            self.compactCountdownRefreshTask = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled, self.manager.currentSnapshot == snapshot else { return }
                self.refreshCompactCountdownWidths()
            }
        }
    }

    /// App teardown also removes the scheduler's system observers and deadline.
    public func shutdownPlugins() {
        viewModel?.cancelToolMenuInteraction()
        viewModel?.activitySurfaceForExpansion = nil
        toolForUserExpansion = nil
        toolContextObservation?.cancel()
        toolContextObservation = nil
        toolPlacementObservation?.cancel()
        toolPlacementObservation = nil
        manager.setPresentationRequestsAllowed(false)
        compactCountdownObservation?.cancel()
        compactCountdownSnapshotObservation?.cancel()
        compactCountdownRefreshTask?.cancel()
        compactCountdownRefreshTask = nil
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

    /// The Host's plugin placement applies to every tool published by that
    /// source. It changes navigation only, never plugin execution or permission.
    public func toolSnapshots(in area: PluginToolArea) -> [ActivitySnapshot] {
        manager.toolSnapshots.filter { toolArea(for: $0.activity.source) == area }
    }

    private func toolArea(for source: ActivitySource) -> PluginToolArea {
        Self.toolArea(for: source, placements: toolPlacementAssignments)
    }

    private static func toolArea(
        for source: ActivitySource,
        placements: [String: PluginToolArea]
    ) -> PluginToolArea {
        source.kind == .plugin ? placements[source.identifier] ?? .tools : .tools
    }

    private func updateToolContext(_ context: ToolContext) {
        toolContext = context
        let area = context.area
        // Crossing regions ends the old lease and gives the newly visible
        // region its own bounded request opportunity.
        if visibleToolArea != area { manager.setPresentationRequestsAllowed(false) }
        visibleToolArea = area
        let placements = toolPlacementAssignments
        manager.setPresentationRequestsAllowed(area != nil, forSource: { source in
            Self.toolArea(for: source, placements: placements) == area
        })
        manager.setPresentationContext(context.state == .compact ? .compact : .expanded)
        if area == nil || manager.selectedToolSnapshot.map({ toolArea(for: $0.activity.source) != area }) == true {
            manager.clearToolSelection()
        }
        if context.state != .compact, let snapshot = toolForUserExpansion {
            toolForUserExpansion = nil
            if context.isAvailable, toolArea(for: snapshot.activity.source) == area {
                // The pointer expansion is the user gesture. Select its exact
                // compact instance only after expanded eligibility is applied.
                _ = manager.selectTool(snapshot)
            }
        }
    }

    private func updateToolPlacements(_ placements: [String: PluginToolArea]) {
        guard placements != toolPlacementAssignments else { return }
        let previous = toolPlacementAssignments
        toolPlacementAssignments = placements
        // Reconcile the new source predicate without opening a fresh context
        // budget or revoking an unrelated tool's existing presentation lease.
        if let selected = manager.selectedToolSnapshot,
           Self.toolArea(for: selected.activity.source, placements: previous)
            != toolArea(for: selected.activity.source) {
            manager.clearToolSelection()
        }
        if let toolContext { updateToolContext(toolContext) }
    }

    /// A user chooses the exact item captured by the Host menu. Inventory
    /// snapshots never authorize renderer actions; only currentSnapshot does.
    @discardableResult
    public func selectTool(_ snapshot: ActivitySnapshot) -> Bool {
        guard let viewModel, viewModel.presentationState == .expanded,
              viewModel.isIslandPanelVisible, !viewModel.isDragging,
              !viewModel.isFileTrayLocked, !viewModel.isTimerCompletionPresented else { return false }
        if let current = manager.current, !current.isTool,
           current.priority == .critical || !current.lifecycle.policy.isInterruptible { return false }
        guard manager.toolSnapshots.contains(where: {
            $0.activity.id == snapshot.activity.id && $0.activity.source == snapshot.activity.source
                && $0.instanceToken == snapshot.instanceToken
        }) else { return false }
        viewModel.selectExpandedSurface(toolArea(for: snapshot.activity.source) == .timer ? .tools : .utilities)
        return manager.selectTool(snapshot)
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
        guard let snapshot = manager.currentSnapshot,
              snapshot.activity.presentation.isCompactVisible else { return IslandCompactLayout(baseSize: baseSize) }
        return .activity(baseSize: baseSize, presentation: snapshot.activity.presentation,
                         reservesPercentageWidth: currentActivityUsesBatteryCompactLayout
                            || currentActivityUsesVolumeCompactLayout,
                         countdownResolver: { self.resolveCountdown($0, for: snapshot) })
    }

    private func refreshCompactCountdownWidths() {
        guard let snapshot = manager.currentSnapshot, snapshot.activity.presentation.isCompactVisible else {
            compactCountdownLayout.update([])
            return
        }
        let layout = compactLayout(forBaseSize: viewModel?.displayLayout.designCompactSize ?? .zero)
        let mode: ActivityPresentation.Mode = layout.usesMinimalPresentation
            ? .minimal : snapshot.activity.presentation.effectiveCollapsedMode
        let references = IslandRenderer.resolvedNode(in: snapshot.activity.presentation, for: mode).countdownReferences
        compactCountdownLayout.update(references.filter { $0.style == .time }.map {
            IslandCompactLayout.countdownTextWidth(resolveCountdown($0, for: snapshot)?.text ?? "--:--")
        })
    }

    /// Compatibility entry point for callers that only need the visible size.
    public func compactShellSize(forBaseSize baseSize: CGSize) -> CGSize {
        compactLayout(forBaseSize: baseSize).size
    }

    /// The rendered shell and the panel's pointer region share all inputs.
    public var expandedShellSize: CGSize {
        guard let viewModel else { return IslandVisualStyle.expandedShellSize }
        if let activity = manager.currentSnapshot?.activity, activity.isTool,
           !viewModel.isTimerCompletionPresented,
           let size = IslandTimerStyle.expandedToolShellSize(for: activity.presentation) {
            return size
        }
        return IslandVisualStyle.expandedShellSize(
            for: viewModel.expandedSurface,
            timerMode: viewModel.timerShellMode,
            hasTrayItems: !viewModel.trayItems.isEmpty,
            hasError: viewModel.lastErrorMessage != nil,
            hasTimerCompletion: viewModel.isTimerCompletionPresented,
            hasPresentedTool: currentActivityUsesToolLayout,
            showsHomeLayerButtons: viewModel.homeSettings.showsLayerButtons
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
        if snapshot.activity.source == CalendarActivityProvider.source,
           let viewModel, viewModel.isDragging || viewModel.isTimerCompletionPresented {
            return false
        }
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
