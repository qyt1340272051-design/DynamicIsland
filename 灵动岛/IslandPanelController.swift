import AppKit
import SwiftUI

@MainActor
final class IslandPanelController {
    private let viewModel: IslandViewModel
    private var panel: NSPanel?
    private var hoverTimer: Timer?
    private var isPointerInsidePanel = false

    init(viewModel: IslandViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        updateFrame(for: panel)
        panel.orderFrontRegardless()
        startHoverTracking()
    }

    func hide() {
        stopHoverTracking()
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.level = .statusBar
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let rootView = IslandView(viewModel: viewModel)
        panel.contentViewController = NSHostingController(rootView: rootView)
        return panel
    }

    private func updateFrame(for panel: NSPanel) {
        guard let screen = NSScreen.main else {
            panel.setFrame(CGRect(origin: .zero, size: IslandPanelGeometry.expandedSize), display: true, animate: false)
            return
        }

        let compactFrame = currentCompactFrame(on: screen)
        viewModel.setCompactPanelSize(compactFrame.size)
        panel.setFrame(currentStablePanelFrame(on: screen), display: true, animate: false)
    }

    private func currentCompactFrame(on screen: NSScreen) -> CGRect {
        let leftArea = screen.auxiliaryTopLeftArea ?? .zero
        let rightArea = screen.auxiliaryTopRightArea ?? .zero

        return IslandPanelGeometry.compactFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            auxiliaryTopLeftArea: leftArea,
            auxiliaryTopRightArea: rightArea
        )
    }

    private func currentCompactPresentationFrame(on screen: NSScreen) -> CGRect {
        let baseFrame = currentCompactFrame(on: screen)
        let presentationSize = IslandVisualStyle.compactShellSize(
            baseSize: baseFrame.size,
            isPlaying: viewModel.isPlaying,
            hasActiveTimer: viewModel.compactTimerMode != nil
        )

        return CGRect(
            x: baseFrame.midX - presentationSize.width / 2,
            y: baseFrame.maxY - presentationSize.height,
            width: presentationSize.width,
            height: presentationSize.height
        )
    }

    private func currentStablePanelFrame(on screen: NSScreen) -> CGRect {
        let leftArea = screen.auxiliaryTopLeftArea ?? .zero
        let rightArea = screen.auxiliaryTopRightArea ?? .zero

        return IslandPanelGeometry.stableFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            auxiliaryTopLeftArea: leftArea,
            auxiliaryTopRightArea: rightArea
        )
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
        guard let screen = NSScreen.main else {
            return panel.frame
        }

        return IslandPanelHoverRegion.hoverFrame(
            panelFrame: panel.frame,
            compactFrame: currentCompactPresentationFrame(on: screen),
            presentationState: viewModel.presentationState,
            isPointerInside: isPointerInsidePanel,
            expandedShellSize: IslandVisualStyle.expandedShellSize
        )
    }
}
