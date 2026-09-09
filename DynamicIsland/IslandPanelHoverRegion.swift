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

        return hoverFrame(for: compactFrame, isPointerInside: isPointerInside)
    }

    static func hoverFrame(for compactFrame: CGRect, isPointerInside: Bool) -> CGRect {
        guard isPointerInside else {
            return compactFrame
        }

        let extraWidth = compactFrame.width * (IslandExpansionAnimation.pointerHoverScale - 1)
        let extraHeight = compactFrame.height * (IslandExpansionAnimation.pointerHoverScale - 1)
        return compactFrame.insetBy(dx: -extraWidth / 2, dy: -extraHeight / 2)
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
