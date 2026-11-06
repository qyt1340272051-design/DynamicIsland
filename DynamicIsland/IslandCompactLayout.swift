import AppKit

/// Host-owned design-point budgets beside the physical camera gap. The gap
/// stays at its original screen position when the two wings have different widths.
public struct IslandCompactLayout: Equatable, Sendable {
    public let size: CGSize
    public let centerOffset: CGFloat
    public let leadingWidth: CGFloat
    public let trailingWidth: CGFloat
    /// An authored minimal leaf, or a safe minimal fallback, occupies only the
    /// trailing wing. The renderer must use that mode rather than center a row.
    public let usesMinimalPresentation: Bool
    /// A Host fallback only; the Activity, its instance and router stay intact.
    public let fallbackMinimalNode: IslandNode?

    public init(baseSize: CGSize, leadingWidth: CGFloat = 0, trailingWidth: CGFloat = 0,
                minimumHeight: CGFloat = 0, usesMinimalPresentation: Bool = false,
                fallbackMinimalNode: IslandNode? = nil) {
        let leading = Self.normalized(leadingWidth)
        let trailing = Self.normalized(trailingWidth)
        self.leadingWidth = leading
        self.trailingWidth = trailing
        self.centerOffset = (trailing - leading) / 2
        self.size = CGSize(width: Self.normalized(baseSize.width) + leading + trailing,
                           height: max(Self.normalized(baseSize.height), Self.normalized(minimumHeight)))
        self.usesMinimalPresentation = usesMinimalPresentation
        self.fallbackMinimalNode = fallbackMinimalNode
    }

    @MainActor
    public static func nativeTimer(baseSize: CGSize, textWidth: CGFloat) -> Self {
        let leading: CGFloat = 26 + wingPadding
        let trailing = normalized(textWidth) + wingPadding
        guard fits(leading: leading, trailing: trailing, baseSize: baseSize) else {
            return ellipsis(baseSize: baseSize)
        }
        return Self(baseSize: baseSize, leadingWidth: leading,
                    trailingWidth: trailing, minimumHeight: 32)
    }

    /// Uses the same 11 pt monospaced face as CompactTimerStatus. Measuring the
    /// formatted emitted value makes fractional ticks stay in one width bucket.
    @MainActor
    public static func nativeTimerTextWidth(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let natural = textWidth(text, font: font)
        return text.count >= 8 ? max(58, natural) : natural
    }

    @MainActor
    public static func activity(baseSize: CGSize, presentation: ActivityPresentation,
                                reservesPercentageWidth: Bool = false) -> Self {
        if presentation.effectiveCollapsedMode == .minimal {
            return minimal(baseSize: baseSize, presentation: presentation)
        }
        let node = IslandRenderer.resolvedNode(in: presentation, for: .compact)
        guard case .hStack(let stack) = node else {
            return minimal(baseSize: baseSize, presentation: presentation)
        }
        let spacers = stack.children.indices.filter {
            if case .spacer = stack.children[$0] { return true }
            return false
        }
        guard spacers.count == 1, let split = spacers.first,
              let leading = measure(Array(stack.children[..<split]),
                                    reservesPercentageWidth: reservesPercentageWidth),
              let trailing = measure(Array(stack.children[(split + 1)...]),
                                     reservesPercentageWidth: reservesPercentageWidth) else {
            return minimal(baseSize: baseSize, presentation: presentation)
        }
        let leadingWidth = leading.width > 0 ? leading.width + wingPadding : 0
        let trailingWidth = trailing.width > 0 ? trailing.width + wingPadding : 0
        guard fits(leading: leadingWidth, trailing: trailingWidth, baseSize: baseSize) else {
            return minimal(baseSize: baseSize, presentation: presentation)
        }
        return Self(baseSize: baseSize, leadingWidth: leadingWidth, trailingWidth: trailingWidth,
                    minimumHeight: contentHeightWithInsets(max(leading.height, trailing.height)))
    }

    private static let wingPadding: CGFloat = 12 // 8 pt outer edge + 4 pt camera clearance.
    private static let minimalPadding: CGFloat = 20 // Renderer removes 8 pt on each side.
    private static let nodeSpacing: CGFloat = 4

    @MainActor
    private static func minimal(baseSize: CGSize, presentation: ActivityPresentation) -> Self {
        let leaf = IslandRenderer.resolvedNode(in: presentation, for: .minimal)
        // HostPolicy resolves malformed payloads to a bounded text leaf. A
        // conservative caption budget is retained if an unknown leaf appears.
        let content = measure(leaf, reservesPercentageWidth: false)
            ?? CGSize(width: max(58, textWidth("Activity", font: captionFont)), height: 16)
        guard fits(leading: 0, trailing: content.width + minimalPadding, baseSize: baseSize) else {
            return ellipsis(baseSize: baseSize)
        }
        return Self(baseSize: baseSize, trailingWidth: content.width + minimalPadding,
                    minimumHeight: content.height + 8, usesMinimalPresentation: true)
    }

    @MainActor
    private static func fits(leading: CGFloat, trailing: CGFloat, baseSize: CGSize) -> Bool {
        let singleWing = availableSingleWingWidth(baseSize: baseSize)
        return leading + trailing <= availableWingWidth(baseSize: baseSize)
            && leading <= singleWing && trailing <= singleWing
    }

    @MainActor
    private static func availableWingWidth(baseSize: CGSize) -> CGFloat {
        max(0, IslandVisualStyle.expandedShellSize.width - normalized(baseSize.width))
    }

    @MainActor
    private static func availableSingleWingWidth(baseSize: CGSize) -> CGFloat {
        max(0, (IslandPanelGeometry.expandedSize.width - normalized(baseSize.width)) / 2)
    }

    @MainActor
    private static func ellipsis(baseSize: CGSize) -> Self {
        // Never clamp a long text leaf into a narrow rectangle and rely on
        // minimumScaleFactor/clipping. Fall back to one fixed Host glyph.
        let width: CGFloat = 16 + minimalPadding
        let available = availableWingWidth(baseSize: baseSize)
        let fitsPanel = availableSingleWingWidth(baseSize: baseSize) >= width
        return Self(baseSize: baseSize, trailingWidth: available >= width && fitsPanel ? width : 0,
                    minimumHeight: 24, usesMinimalPresentation: true,
                    fallbackMinimalNode: .icon(.init("ellipsis")))
    }

    @MainActor
    private static func measure(_ nodes: [IslandNode], reservesPercentageWidth: Bool) -> CGSize? {
        var sizes: [CGSize] = []
        for node in nodes {
            guard let size = measure(node, reservesPercentageWidth: reservesPercentageWidth) else { return nil }
            sizes.append(size)
        }
        return CGSize(width: sizes.reduce(0) { $0 + $1.width }
                        + CGFloat(max(0, sizes.count - 1)) * nodeSpacing,
                      height: sizes.map(\.height).max() ?? 0)
    }

    @MainActor
    private static func measure(_ node: IslandNode, reservesPercentageWidth: Bool) -> CGSize? {
        switch node {
        case .text(let value):
            let text = reservesPercentageWidth && isPercentage(value.content) ? "100%" : value.content
            return CGSize(width: textWidth(text, font: captionFont), height: captionHeight)
        case .icon:
            return CGSize(width: 16, height: 16)
        case .image(let value):
            let side = IslandDesignTokens.imageSide(value.size, mode: .compact)
            return CGSize(width: side, height: side)
        case .countdown(let value):
            guard value.style == .time else { return nil }
            // A changing Host countdown does not rebuild the outer island on
            // each tick. Its longest supported HH:MM:SS frame is reserved.
            return CGSize(width: 58, height: captionHeight)
        case .progress(let value):
            guard value.style == .battery else { return nil }
            return CGSize(width: 42 + 2 + 3, height: 20)
        case .hStack(let stack):
            return measure(stack.children, reservesPercentageWidth: reservesPercentageWidth)
        case .vStack, .zStack, .spacer, .divider, .button, .toggle, .slider:
            return nil
        }
    }

    @MainActor
    private static var captionFont: NSFont {
        NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption2, options: [:]).pointSize,
                          weight: .medium)
    }

    @MainActor
    private static var captionHeight: CGFloat {
        ceil(captionFont.ascender - captionFont.descender + captionFont.leading)
    }

    @MainActor
    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }

    private static func isPercentage(_ text: String) -> Bool {
        guard text.hasSuffix("%"), let value = Int(text.dropLast()) else { return false }
        return (0...100).contains(value)
    }

    private static func normalized(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value) : 0
    }

    private static func contentHeightWithInsets(_ height: CGFloat) -> CGFloat {
        height > 24 ? height + 6 : height + 8
    }
}
