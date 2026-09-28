import AppKit
import Combine
import SwiftUI

@MainActor
final class IslandPanelController {
    private let viewModel: IslandViewModel
    private let activityRuntime: IslandActivityRuntime
    private let screenManager: ScreenManager
    private let workspaceNotificationCenter: NotificationCenter
    private let applicationNotificationCenter: NotificationCenter
    private var panel: NSPanel?
    private var hoverTimer: Timer?
    private var screenObservation: AnyCancellable?
    private var isPointerInsidePanel = false
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
        activityRuntime: IslandActivityRuntime? = nil
    ) {
        self.viewModel = viewModel
        self.activityRuntime = activityRuntime ?? IslandActivityRuntime(viewModel: viewModel)
        self.screenManager = screenManager
        self.workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        self.applicationNotificationCenter = .default
        observeScreenChanges()
    }

    func show() {
        screenManager.startMonitoring()
        let panel = panel ?? makePanel()
        self.panel = panel
        updateFrame(for: panel)
        panel.orderFrontRegardless()
        stabilityMonitor.start()
        startHoverTracking()
    }

    func hide() {
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

        let rootView = IslandView(viewModel: viewModel, activityRuntime: activityRuntime)
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

        let compactFrame = currentCompactFrame(in: screen)
        viewModel.setCompactPanelSize(compactFrame.size)
        panel.setFrame(currentStablePanelFrame(in: screen), display: true, animate: false)
    }

    private func currentCompactFrame(in screen: ScreenEnvironment) -> CGRect {
        IslandPanelGeometry.compactFrame(in: screen)
    }

    private func currentCompactPresentationFrame(in screen: ScreenEnvironment) -> CGRect {
        let baseFrame = currentCompactFrame(in: screen)
        let presentationSize = IslandVisualStyle.compactShellSize(
            baseSize: baseFrame.size,
            hasCompactActivity: activityRuntime.isCompactActivityVisible,
            hasActiveTimer: viewModel.compactTimerMode != nil
                && !(activityRuntime.prioritizesCurrentActivityOverLegacyContent
                    && activityRuntime.isCompactActivityVisible)
        )

        return CGRect(
            x: baseFrame.midX - presentationSize.width / 2,
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
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.updatePointerContainment()
            }
        }
    }

    private func stopHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        isPointerInsidePanel = false
        viewModel.endHovering()
    }

    private func updatePointerContainment() {
        guard let panel, panel.isVisible else {
            return
        }

        let hoverFrame = currentHoverFrame(for: panel)
        let containsPointer = IslandPanelHoverRegion.contains(NSEvent.mouseLocation, in: hoverFrame)
        guard containsPointer != isPointerInsidePanel else {
            return
        }

        isPointerInsidePanel = containsPointer
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
            expandedShellSize: IslandVisualStyle.expandedShellSize(
                for: viewModel.expandedSurface,
                timerMode: viewModel.timerTools.selectedMode,
                hasTrayItems: !viewModel.trayItems.isEmpty,
                hasError: viewModel.lastErrorMessage != nil,
                hasTimerCompletion: viewModel.timerTools.completedMode != nil
            )
        )
    }
}
