import CoreGraphics

public enum IslandVisualStyle {
    public enum CompactActivityLayout: Equatable, Sendable {
        case standard
        case volume
        case battery
    }

    public static let expandedShellSize = CGSize(width: 480, height: 200)
    public static let expandedMusicHeight: CGFloat = 200
    public static let expandedTimerHeight: CGFloat = 190
    public static let expandedFileTrayHeight: CGFloat = 164
    public static let expandedCompactContentHeight: CGFloat = 152
    public static let expandedContentSize = CGSize(width: 468, height: 200)
    public static let expandedContentPadding: CGFloat = 12
    public static let expandedSurfaceSwitcherHeight: CGFloat = 28
    public static let expandedSurfaceSpacing: CGFloat = 8
    public static let expandedShellCornerRadius: CGFloat = 26
    public static let activityCompactHorizontalExpansion: CGFloat = 72
    /// Leaves enough room in both display wings for the volume glyph and the
    /// widest percentage label (`100%`) without touching a physical notch.
    public static let volumeCompactHorizontalExpansion: CGFloat = 96
    /// Adds a 100 pt display wing on each side of the physical notch. After
    /// renderer insets, the right wing still fits `100%` and the battery gauge.
    public static let batteryCompactHorizontalExpansion: CGFloat = 200
    public static let timerCompactHorizontalExpansion: CGFloat = 126
    public static let hoverShellShadowOpacity: Double = 0.28
    public static let hoverShellShadowRadius: CGFloat = 18
    public static let hoverShellShadowYOffset: CGFloat = 8
    public static let expandedShellStrokeOpacity: Double = 0
    public static let draggingShellStrokeOpacity: Double = 1

    public static func expandedShellSize(
        for surface: IslandExpandedSurface,
        timerMode: IslandTimerToolMode,
        hasTrayItems: Bool,
        hasError: Bool,
        hasTimerCompletion: Bool,
        hasPresentedTool: Bool = false
    ) -> CGSize {
        // The currently presented tool owns the full Host canvas. Hidden
        // legacy tab state must not shorten its validated content budget.
        if hasPresentedTool { return expandedShellSize }
        let height: CGFloat
        if hasTimerCompletion || (surface == .fileTray && hasError) {
            height = expandedTimerHeight
        } else {
            switch surface {
            case .music:
                height = expandedMusicHeight
            case .fileTray:
                height = hasTrayItems ? expandedFileTrayHeight : expandedCompactContentHeight
            case .tools:
                height = timerMode == .stopwatch ? expandedCompactContentHeight : expandedTimerHeight
            }
        }

        return CGSize(width: expandedShellSize.width, height: height)
    }

    public static func shellShadowOpacity(isCompactHovering: Bool) -> Double {
        isCompactHovering ? hoverShellShadowOpacity : 0
    }

    public static func compactShellSize(
        baseSize: CGSize,
        hasCompactActivity: Bool,
        hasActiveTimer: Bool = false,
        activityLayout: CompactActivityLayout = .standard
    ) -> CGSize {
        let horizontalExpansion: CGFloat
        if hasActiveTimer {
            horizontalExpansion = timerCompactHorizontalExpansion
        } else if hasCompactActivity {
            switch activityLayout {
            case .standard:
                horizontalExpansion = activityCompactHorizontalExpansion
            case .volume:
                horizontalExpansion = volumeCompactHorizontalExpansion
            case .battery:
                horizontalExpansion = batteryCompactHorizontalExpansion
            }
        } else {
            horizontalExpansion = 0
        }

        return CGSize(
            width: horizontalExpansion > 0
                ? min(baseSize.width + horizontalExpansion, expandedShellSize.width)
                : baseSize.width,
            height: baseSize.height
        )
    }

    public static func compactContentOpacity(isExpanded: Bool, hasCompactContent: Bool) -> Double {
        !isExpanded && hasCompactContent ? 1 : 0
    }

    public static func shellCornerRadii(isExpanded: Bool, shellHeight: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        if isExpanded {
            return (expandedShellCornerRadius, expandedShellCornerRadius)
        }

        return (0, shellHeight / 2)
    }
}
