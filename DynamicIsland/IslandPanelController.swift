import AppKit
import Combine
import SwiftUI

@MainActor
final class IslandPanelController {
    private let viewModel: IslandViewModel
    private let activityRuntime: IslandActivityRuntime
    private let screenManager: ScreenManager
    private let pointerLocation: () -> CGPoint
    private let onOpenSettings: @MainActor () -> Void
    private let workspaceNotificationCenter: NotificationCenter
    private let applicationNotificationCenter: NotificationCenter
    private var panel: NSPanel?
    private var hoverTimer: Timer?
    private var screenObservation: AnyCancellable?
    private var isPointerInsidePanel = false
    private var retainedHoverEntryFrame: CGRect?
    private lazy var stabilityMonitor = IslandPanelStabilityMonitor(
        workspaceNotificationCenter: workspaceNotificationCenter,
        applicationNotificationCenter: applicationNotificationCenter
    ) { [weak self] in
        self?.restorePanelAfterEnvironmentChange()
    }

    var diagnosticPanelFrame: CGRect? {
        panel?.frame
    }

    var isPanelVisible: Bool {
        panel?.isVisible ?? false
    }

    convenience init(viewModel: IslandViewModel) {
        self.init(viewModel: viewModel, screenManager: ScreenManager())
    }

    init(
        viewModel: IslandViewModel,
        screenManager: ScreenManager,
        activityRuntime: IslandActivityRuntime? = nil,
        pointerLocation: @escaping () -> CGPoint = { NSEvent.mouseLocation },
        onOpenSettings: @escaping @MainActor () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.activityRuntime = activityRuntime ?? IslandActivityRuntime(viewModel: viewModel)
        self.screenManager = screenManager
        self.pointerLocation = pointerLocation
        self.onOpenSettings = onOpenSettings
        self.workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        self.applicationNotificationCenter = .default
        viewModel.refreshPointerContainmentBeforeToolMenuReturn = { [weak self] in
            self?.updatePointerContainment(force: true)
        }
        observeScreenChanges()
    }

    func show() {
        viewModel.setIslandPanelVisible(true)
        screenManager.startMonitoring()
        let panel = panel ?? makePanel()
        self.panel = panel
        updateFrame(for: panel)
        panel.orderFrontRegardless()
        stabilityMonitor.start()
        startHoverTracking()
    }

    func hide() {
        viewModel.setIslandPanelVisible(false)
        stopHoverTracking()
        stabilityMonitor.stop()
        screenManager.stopMonitoring()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        IslandPanelWindowPolicy.apply(to: panel)

        let rootView = IslandView(viewModel: viewModel, activityRuntime: activityRuntime,
                                  onOpenSettings: onOpenSettings)
        panel.contentViewController = NSHostingController(rootView: rootView)
        return panel
    }

    private func updateFrame(for panel: NSPanel) {
        guard let screen = screenManager.activeScreen else {
            if panel.frame.isEmpty {
                panel.setFrame(CGRect(origin: .zero, size: IslandPanelGeometry.expandedSize), display: true, animate: false)
            }
            return
        }

        let frame = currentStablePanelFrame(in: screen)
        if panel.frame != frame || viewModel.displayLayout != IslandDisplayLayout(environment: screen) {
            retainedHoverEntryFrame = nil
        }
        viewModel.setScreenEnvironment(screen)
        panel.setFrame(frame, display: true, animate: false)
    }

    private func currentCompactFrame(in screen: ScreenEnvironment) -> CGRect {
        IslandPanelGeometry.compactFrame(in: screen)
    }

    private func currentCompactPresentationFrame(in screen: ScreenEnvironment) -> CGRect {
        let baseFrame = currentCompactFrame(in: screen)
        let layout = IslandDisplayLayout(environment: screen)
        let compactLayout = activityRuntime.compactLayout(forBaseSize: layout.designCompactSize)
        let presentationSize = layout.scaled(compactLayout.size)

        return CGRect(
            x: baseFrame.midX + compactLayout.centerOffset * layout.scale - presentationSize.width / 2,
            y: baseFrame.maxY - presentationSize.height,
            width: presentationSize.width,
            height: presentationSize.height
        )
    }

    private func currentStablePanelFrame(in screen: ScreenEnvironment) -> CGRect {
        IslandPanelGeometry.stableFrame(in: screen)
    }

    private func observeScreenChanges() {
        screenObservation = screenManager.$activeScreen
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, let panel = self.panel else {
                    return
                }
                self.updateFrame(for: panel)
                if panel.isVisible {
                    panel.orderFrontRegardless()
                }
                self.updatePointerContainment()
            }
    }

    private func restorePanelAfterEnvironmentChange() {
        guard let panel, panel.isVisible else {
            return
        }

        screenManager.refresh()
        updateFrame(for: panel)
        panel.orderFrontRegardless()
        updatePointerContainment()
    }

    private func startHoverTracking() {
        guard hoverTimer == nil else {
            return
        }

        updatePointerContainment()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            // The main run loop also fires this in AppKit tracking modes.
            // Do not enqueue a Task behind the job that is tracking input.
            MainActor.assumeIsolated {
                self?.updatePointerContainment()
            }
        }
        hoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        isPointerInsidePanel = false
        retainedHoverEntryFrame = nil
        viewModel.endHovering()
    }

    private func updatePointerContainment(force: Bool = false) {
        guard let panel, panel.isVisible else {
            return
        }

        let hoverFrame = currentHoverFrame(for: panel)
        let containsPointer = IslandPanelHoverRegion.contains(
            pointerLocation(), in: hoverFrame, retainedEntryFrame: retainedHoverEntryFrame)
        let didChange = containsPointer != isPointerInsidePanel
        isPointerInsidePanel = containsPointer
        if !containsPointer {
            retainedHoverEntryFrame = nil
        } else if didChange, viewModel.presentationState == .compact {
            // Keep only the admitted top strip, not an invisible rectangle
            // spanning the entire width and height of both shell sizes.
            // Include the slight pointer feedback so moving within that
            // visible strip during the delay cannot cancel the expansion.
            retainedHoverEntryFrame = currentHoverFrame(for: panel)
        }
        guard force || didChange || containsPointer != viewModel.isPointerInside
                || (containsPointer && !viewModel.isHovering) else {
            return
        }

        if containsPointer {
            viewModel.beginHoveringAfterDelay()
        } else {
            viewModel.endHovering()
        }
    }

    private func currentHoverFrame(for panel: NSPanel) -> CGRect {
        guard let screen = screenManager.activeScreen else {
            return panel.frame
        }

        return IslandPanelHoverRegion.hoverFrame(
            panelFrame: panel.frame,
            compactFrame: currentCompactPresentationFrame(in: screen),
            presentationState: viewModel.presentationState,
            isPointerInside: isPointerInsidePanel,
            expandedShellSize: viewModel.displayLayout.scaledExpanded(activityRuntime.expandedShellSize)
        )
    }
}
