import CoreGraphics

/// Resolves native drawing points for the compact and denser expanded surfaces.
/// The physical camera area changes its logical height when macOS scaling changes;
/// the backing scale only controls raster density and is not a layout multiplier.
public struct IslandDisplayLayout: Equatable, Sendable {
    public static let referenceNotchHeight: CGFloat = 32

    public let scale: CGFloat
    public let compactSize: CGSize

    public var expandedScale: CGFloat { scale * IslandVisualStyle.expandedDensity }

    public var designCompactSize: CGSize { unscaled(compactSize) }
    public var panelSize: CGSize { scaled(IslandPanelGeometry.expandedSize) }

    /// Unscaled entry point for previews and callers without a screen environment.
    init(compactSize: CGSize = IslandPanelGeometry.compactSize) {
        self.compactSize = compactSize
        self.scale = 1
    }

    public init(environment: ScreenEnvironment) {
        let compactFrame = IslandPanelGeometry.compactFrame(in: environment)
        compactSize = compactFrame.size

        // Use the auxiliary camera strip, not visibleFrame: auto-hiding the menu
        // bar or opening a full-screen Space must not resize the entire island.
        let auxiliaryHeight = min(environment.auxiliaryTopLeftArea.height, environment.auxiliaryTopRightArea.height)
        let auxiliaryGap = environment.auxiliaryTopRightArea.minX - environment.auxiliaryTopLeftArea.maxX
        let hasValidNotch = environment.hasNotch
            && auxiliaryHeight.isFinite && auxiliaryHeight > 0
            && auxiliaryGap.isFinite && auxiliaryGap > 0
        let notchScale = hasValidNotch
            ? compactFrame.height / Self.referenceNotchHeight
            : 1
        let screenFit = min(
            environment.frame.width / IslandPanelGeometry.expandedSize.width,
            environment.frame.height / IslandPanelGeometry.expandedSize.height
        )
        let resolvedScale = min(notchScale, screenFit)
        scale = resolvedScale.isFinite && resolvedScale > 0 ? resolvedScale : 1
    }

    public func scaled(_ size: CGSize) -> CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// Lay out expanded glyphs and controls directly at their final point size;
    /// this does not introduce a bitmap or a second view transform.
    public func scaledExpanded(_ size: CGSize) -> CGSize {
        CGSize(width: size.width * expandedScale, height: size.height * expandedScale)
    }

    public func unscaled(_ size: CGSize) -> CGSize {
        CGSize(width: size.width / scale, height: size.height / scale)
    }
}
