import CoreGraphics

enum IslandPanelHoverRegion {
    static let exitTolerance: CGFloat = 2

    static func hoverFrame(
        panelFrame: CGRect,
        compactFrame: CGRect,
        presentationState: IslandPresentationState,
        isPointerInside: Bool,
        expandedShellSize: CGSize
    ) -> CGRect {
        guard presentationState == .compact else {
            return expandedShellFrame(in: panelFrame, size: expandedShellSize)
        }

        return hoverFrame(for: compactFrame, isPointerInside: isPointerInside,
                          maximumWidth: compactHoverMaximumWidth(
                            panelWidth: panelFrame.width, expandedShellWidth: expandedShellSize.width,
                            centerOffset: compactFrame.midX - panelFrame.midX))
    }

    /// Asymmetric wings must keep their hover feedback inside the fixed panel.
    static func compactHoverMaximumWidth(panelWidth: CGFloat, expandedShellWidth: CGFloat,
                                         centerOffset: CGFloat) -> CGFloat {
        max(0, min(expandedShellWidth, panelWidth - 2 * abs(centerOffset)))
    }

    static func hoverFrame(for compactFrame: CGRect, isPointerInside: Bool,
                           maximumWidth: CGFloat = .infinity) -> CGRect {
        guard isPointerInside else { return compactFrame }
        let width = min(compactFrame.width * IslandExpansionAnimation.pointerHoverScale, maximumWidth)
        let height = compactFrame.height * IslandExpansionAnimation.pointerHoverScale
        return CGRect(x: compactFrame.midX - width / 2, y: compactFrame.maxY - height,
                      width: width, height: height)
    }

    static func expandedShellFrame(in panelFrame: CGRect, size: CGSize) -> CGRect {
        CGRect(
            x: panelFrame.midX - size.width / 2,
            y: panelFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    static func contains(_ point: CGPoint, in panelFrame: CGRect) -> Bool {
        panelFrame.insetBy(dx: -exitTolerance, dy: -exitTolerance).contains(point)
    }
}
