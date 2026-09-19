import CoreGraphics

enum IslandPlaybackProgressAppearance {
    static let dotDiameter: CGFloat = 10

    static func showsDot(canSeek: Bool, hovered: Bool, dragging: Bool) -> Bool {
        canSeek && (hovered || dragging)
    }

    static func dotOffset(progress: Double, width: CGFloat) -> CGFloat {
        guard progress.isFinite, width.isFinite, width > 0 else { return 0 }
        let radius = dotDiameter / 2
        let center = min(max(width * CGFloat(progress), radius), max(width - radius, radius))
        return center - radius
    }
}
