import AppKit
import CoreGraphics
import SwiftUI

/// Values a plugin may request. The Host resolves them to platform appearance;
/// plugin payloads never carry point sizes, color components, or padding values.
public nonisolated enum IslandTypographyToken: String, Codable, CaseIterable, Sendable {
    case caption
    case body
    case headline
    case title
    case metric
}

public nonisolated enum IslandSpacingToken: String, Codable, CaseIterable, Sendable {
    case xs
    case sm
    case md
    case lg
}

public nonisolated enum IslandSemanticColorToken: String, Codable, CaseIterable, Sendable {
    case primary
    case secondary
    case accent
    case success
    case warning
    case danger
}

public nonisolated enum IslandCornerRadiusToken: String, Codable, CaseIterable, Sendable {
    case sm
    case md
}

/// Host-owned mappings for the finite plugin visual vocabulary.
public enum IslandDesignTokens {
    /// Semantic text styles allow the system to respond to larger text settings.
    /// The renderer remains responsible for truncation and accessibility labels
    /// within the island's fixed physical bounds.
    public static func font(for token: IslandTypographyToken, scale: CGFloat = 1) -> Font {
        let scale = normalizedLayoutScale(scale)
        guard scale == 1 else {
            let typography: (style: NSFont.TextStyle, weight: Font.Weight, design: Font.Design)
            switch token {
            case .caption: typography = (.caption2, .medium, .default)
            case .body: typography = (.caption1, .regular, .default)
            case .headline: typography = (.subheadline, .semibold, .default)
            case .title: typography = (.headline, .semibold, .default)
            case .metric: typography = (.title1, .semibold, .monospaced)
            }
            let preferredSize = NSFont.preferredFont(forTextStyle: typography.style, options: [:]).pointSize
            return .system(size: preferredSize * scale, weight: typography.weight, design: typography.design)
        }
        // Retain the existing semantic styles at the reference scale.
        switch token {
        case .caption: return .system(.caption2, weight: .medium)
        case .body: return .system(.caption, weight: .regular)
        case .headline: return .system(.subheadline, weight: .semibold)
        case .title: return .system(.headline, weight: .semibold)
        case .metric: return .system(.title, design: .monospaced, weight: .semibold)
        }
    }

    public static func spacing(_ token: IslandSpacingToken, scale: CGFloat = 1) -> CGFloat {
        let value: CGFloat
        switch token {
        case .xs: value = 4
        case .sm: value = 8
        case .md: value = 12
        case .lg: value = 16
        }
        return value * normalizedLayoutScale(scale)
    }

    public static func cornerRadius(_ token: IslandCornerRadiusToken, scale: CGFloat = 1) -> CGFloat {
        let value: CGFloat
        switch token {
        case .sm: value = 6
        case .md: value = 10
        }
        return value * normalizedLayoutScale(scale)
    }

    /// The smaller expanded Host uses 112 design points for album art. The
    /// native image is resolved directly at the final display-point size.
    public static func imageSide(_ token: IslandImageSizeToken, mode: ActivityPresentation.Mode,
                                 scale: CGFloat = 1) -> CGFloat {
        let value: CGFloat
        switch token {
        case .icon: value = mode == .expanded ? 20 : 16
        case .thumbnail: value = 26
        case .artwork: value = 112
        }
        return value * normalizedLayoutScale(scale)
    }

    static func normalizedLayoutScale(_ scale: CGFloat) -> CGFloat {
        scale.isFinite && scale > 0 ? scale : 1
    }

    /// The app's island shell is black in both system appearances. Resolve text
    /// and state colors against that actual surface, and strengthen secondary
    /// text when Increase Contrast is enabled.
    public static func color(
        for token: IslandSemanticColorToken,
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast = .standard
    ) -> Color {
        let resolved = resolvedColor(for: token, colorScheme: colorScheme, contrast: contrast)
        return Color(.sRGB, red: resolved.red, green: resolved.green, blue: resolved.blue, opacity: 1)
    }

    /// Compact dimensions come from the detected notch and current Host state.
    /// A plugin cannot specify a preferred shell size.
    public static func compactShellSize(
        baseSize: CGSize,
        hasCompactActivity: Bool,
        hasActiveTimer: Bool
    ) -> CGSize {
        IslandVisualStyle.compactShellSize(
            baseSize: baseSize,
            hasCompactActivity: hasCompactActivity,
            hasActiveTimer: hasActiveTimer
        )
    }

    /// The Host selects the expanded height for its active surface and state.
    public static func expandedShellSize(
        for surface: IslandExpandedSurface,
        timerMode: IslandTimerToolMode,
        hasTrayItems: Bool,
        hasError: Bool,
        hasTimerCompletion: Bool
    ) -> CGSize {
        IslandVisualStyle.expandedShellSize(
            for: surface,
            timerMode: timerMode,
            hasTrayItems: hasTrayItems,
            hasError: hasError,
            hasTimerCompletion: hasTimerCompletion
        )
    }

    /// Maximum existing expanded canvas; visible height may be smaller when
    /// the Host chooses one of its compact expanded shells.
    public static var expandedCanvasSize: CGSize { IslandVisualStyle.expandedContentSize }

    static func resolvedColor(
        for token: IslandSemanticColorToken,
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast
    ) -> ResolvedColor {
        switch token {
        case .primary:
            return ResolvedColor(red: 1, green: 1, blue: 1)
        case .secondary:
            let component = contrast == .increased ? 0.95 : 0.76
            return ResolvedColor(red: component, green: component, blue: component)
        case .accent:
            return colorScheme == .dark
                ? ResolvedColor(red: 0.39, green: 0.82, blue: 1)
                : ResolvedColor(red: 0.35, green: 0.79, blue: 0.98)
        case .success:
            return ResolvedColor(red: 0.35, green: 0.86, blue: 0.55)
        case .warning:
            return ResolvedColor(red: 1, green: 0.73, blue: 0.28)
        case .danger:
            return ResolvedColor(red: 1, green: 0.42, blue: 0.40)
        }
    }

    nonisolated struct ResolvedColor: Equatable {
        let red: Double
        let green: Double
        let blue: Double
    }
}
