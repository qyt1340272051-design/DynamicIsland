import AppKit
import CoreGraphics

public enum IslandPanelGeometry {
    public static let compactWidth: CGFloat = 260
    public static let fallbackTopReservedHeight: CGFloat = 24
    public static var compactSize: CGSize {
        compactSize(forTopReservedHeight: NSStatusBar.system.thickness)
    }
    public static let expandedSize = CGSize(width: 520, height: 240)

    public static func compactSize(forTopReservedHeight topReservedHeight: CGFloat) -> CGSize {
        CGSize(width: compactWidth, height: normalizedTopReservedHeight(topReservedHeight))
    }

    public static func compactFrame(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        auxiliaryTopLeftArea: CGRect,
        auxiliaryTopRightArea: CGRect
    ) -> CGRect {
        let notchCenterX = notchCenter(
            screenFrame: screenFrame,
            auxiliaryTopLeftArea: auxiliaryTopLeftArea,
            auxiliaryTopRightArea: auxiliaryTopRightArea
        )
        let topPadding: CGFloat = 0
        let size = CGSize(
            width: compactWidthForNotch(
                auxiliaryTopLeftArea: auxiliaryTopLeftArea,
                auxiliaryTopRightArea: auxiliaryTopRightArea
            ),
            height: compactHeight(
                screenFrame: screenFrame,
                visibleFrame: visibleFrame,
                auxiliaryTopLeftArea: auxiliaryTopLeftArea,
                auxiliaryTopRightArea: auxiliaryTopRightArea
            )
        )
        let originX = notchCenterX - size.width / 2
        let originY = screenFrame.maxY - size.height - topPadding

        return CGRect(
            x: originX.rounded(.toNearestOrAwayFromZero),
            y: originY.rounded(.toNearestOrAwayFromZero),
            width: size.width,
            height: size.height
        )
    }

    public static func expandedFrame(
        screenFrame: CGRect,
        auxiliaryTopLeftArea: CGRect,
        auxiliaryTopRightArea: CGRect,
        safeAreaInsetsTop: CGFloat
    ) -> CGRect {
        let notchCenterX = notchCenter(
            screenFrame: screenFrame,
            auxiliaryTopLeftArea: auxiliaryTopLeftArea,
            auxiliaryTopRightArea: auxiliaryTopRightArea
        )
        let topPadding: CGFloat = 0
        let originX = notchCenterX - expandedSize.width / 2
        let originY = screenFrame.maxY - expandedSize.height - topPadding

        return CGRect(
            x: originX.rounded(.toNearestOrAwayFromZero),
            y: originY.rounded(.toNearestOrAwayFromZero),
            width: expandedSize.width,
            height: expandedSize.height
        )
    }

    public static func stableFrame(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        auxiliaryTopLeftArea: CGRect,
        auxiliaryTopRightArea: CGRect
    ) -> CGRect {
        expandedFrame(
            screenFrame: screenFrame,
            auxiliaryTopLeftArea: auxiliaryTopLeftArea,
            auxiliaryTopRightArea: auxiliaryTopRightArea,
            safeAreaInsetsTop: topReservedHeight(screenFrame: screenFrame, visibleFrame: visibleFrame)
        )
    }

    private static func notchCenter(
        screenFrame: CGRect,
        auxiliaryTopLeftArea: CGRect,
        auxiliaryTopRightArea: CGRect
    ) -> CGFloat {
        guard !auxiliaryTopLeftArea.isEmpty, !auxiliaryTopRightArea.isEmpty else {
            return screenFrame.midX
        }

        let center = (auxiliaryTopLeftArea.maxX + auxiliaryTopRightArea.minX) / 2
        if center >= screenFrame.minX, center <= screenFrame.maxX {
            return center
        }

        let screenRelativeCenter = center + screenFrame.minX
        if screenRelativeCenter >= screenFrame.minX, screenRelativeCenter <= screenFrame.maxX {
            return screenRelativeCenter
        }

        return screenFrame.midX
    }

    private static func topReservedHeight(screenFrame: CGRect, visibleFrame: CGRect) -> CGFloat {
        screenFrame.maxY - visibleFrame.maxY
    }

    private static func compactHeight(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        auxiliaryTopLeftArea: CGRect,
        auxiliaryTopRightArea: CGRect
    ) -> CGFloat {
        if !auxiliaryTopLeftArea.isEmpty, !auxiliaryTopRightArea.isEmpty {
            return normalizedTopReservedHeight(min(auxiliaryTopLeftArea.height, auxiliaryTopRightArea.height))
        }

        return normalizedTopReservedHeight(topReservedHeight(screenFrame: screenFrame, visibleFrame: visibleFrame))
    }

    private static func compactWidthForNotch(
        auxiliaryTopLeftArea: CGRect,
        auxiliaryTopRightArea: CGRect
    ) -> CGFloat {
        guard !auxiliaryTopLeftArea.isEmpty, !auxiliaryTopRightArea.isEmpty else {
            return compactWidth
        }

        let notchWidth = auxiliaryTopRightArea.minX - auxiliaryTopLeftArea.maxX
        return notchWidth > 0 ? notchWidth : compactWidth
    }

    private static func normalizedTopReservedHeight(_ height: CGFloat) -> CGFloat {
        height > 0 ? height : fallbackTopReservedHeight
    }
}
