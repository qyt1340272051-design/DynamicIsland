import AppKit
import SwiftUI

/// A bounded interaction emitted by the Host renderer. The Activity owner and
/// publish generation are supplied by the caller when it routes this action.
public nonisolated enum IslandRenderActionValue: Equatable, Sendable {
    case none
    case toggle(Bool)
    /// A finite value in the inclusive range 0...1.
    case slider(Double)
    /// Final bounded value emitted when the user ends a slider edit.
    case sliderCommit(Double)
}

/// Keeps the thumb under the pointer while Activity updates arrive during a
/// drag. A committed value remains local until the next presentation sync.
nonisolated struct IslandSliderInteractionState {
    private var values: [String: Double] = [:]
    private var editingIDs: Set<String> = []

    func displayedValue(for actionID: String, fallback: Double) -> Double {
        values[actionID] ?? fallback
    }

    mutating func beginEditing(_ actionID: String) {
        editingIDs.insert(actionID)
    }

    @discardableResult
    mutating func update(_ actionID: String, value: Double, fallback: Double) -> Double {
        let bounded = value.isFinite ? min(1, max(0, value)) : fallback
        values[actionID] = bounded
        return bounded
    }

    mutating func endEditing(_ actionID: String, fallback: Double) -> Double {
        editingIDs.remove(actionID)
        return values[actionID] ?? fallback
    }

    mutating func presentationDidChange() {
        values = values.filter { editingIDs.contains($0.key) }
    }
}

public nonisolated struct IslandRenderAction: Equatable, Sendable {
    public let actionID: String
    public let value: IslandRenderActionValue

    public init(actionID: String, value: IslandRenderActionValue) {
        self.actionID = actionID
        self.value = value
    }
}

/// The sole Host mapping from a validated IslandNode tree to SwiftUI. Image
/// identifiers are resolved by the caller; this view never opens a path or URL.
public struct IslandRenderer: View {
    public typealias ImageResolver = (IslandNode.ImageSource) -> NSImage?
    public typealias CountdownResolver = (IslandNode.Countdown) -> IslandCountdownDisplayValue?

    public let presentation: ActivityPresentation
    public let mode: ActivityPresentation.Mode
    public let shellSize: CGSize
    private let imageResolver: ImageResolver
    private let countdownResolver: CountdownResolver
    private let isVisible: Bool
    private let displayClock: IslandCountdownDisplayClock
    private let onAction: (IslandRenderAction) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandLayoutScale) private var layoutScale
    @State private var hoveredActionID: String?
    @State private var toggleValues: [String: Bool] = [:]
    @State private var sliderInteraction = IslandSliderInteractionState()

    public init(
        presentation: ActivityPresentation,
        mode: ActivityPresentation.Mode,
        shellSize: CGSize,
        imageResolver: @escaping ImageResolver = { _ in nil },
        countdownResolver: @escaping CountdownResolver = { _ in nil },
        isVisible: Bool = true,
        displayClock: IslandCountdownDisplayClock? = nil,
        onAction: @escaping (IslandRenderAction) -> Void = { _ in }
    ) {
        self.presentation = presentation
        self.mode = mode
        self.shellSize = shellSize
        self.imageResolver = imageResolver
        self.countdownResolver = countdownResolver
        self.isVisible = isVisible
        self.displayClock = displayClock ?? .shared
        self.onAction = onAction
    }

    public var body: some View {
        let size = Self.contentSize(for: mode, shellSize: shellSize, layoutScale: layoutScale)
        let alignment: Alignment = mode == .expanded ? .topLeading : .center
        ViewThatFits(in: [.horizontal, .vertical]) {
            renderedNode(Self.resolvedNode(in: presentation, for: mode), depth: 1)
            fallbackSummary
        }
        .frame(width: size.width, height: size.height, alignment: alignment)
        .contentShape(Rectangle())
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: mode)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: presentation)
        .onChange(of: presentation) { _, _ in
            toggleValues.removeAll()
            sliderInteraction.presentationDidChange()
        }
    }

    /// The Host supplies the shell. Expanded content reserves the switcher and
    /// padding used by IslandView; plugin trees cannot grow the shell.
    public static func contentSize(for mode: ActivityPresentation.Mode, shellSize: CGSize,
                                   layoutScale: CGFloat = 1) -> CGSize {
        guard shellSize.width.isFinite, shellSize.height.isFinite else { return .zero }
        let scale = IslandDesignTokens.normalizedLayoutScale(layoutScale)
        let width = max(0, shellSize.width / scale)
        let height = max(0, shellSize.height / scale)
        let designSize: CGSize
        switch mode {
        case .minimal, .compact:
            designSize = CGSize(width: max(0, width - 2 * IslandDesignTokens.spacing(.sm)), height: height)
        case .expanded:
            designSize = CGSize(
                width: min(IslandDesignTokens.expandedCanvasSize.width,
                           max(0, width - 2 * IslandVisualStyle.expandedContentPadding)),
                height: ActivityPresentation.HostPolicy.expandedContentHeight(forHostShellHeight: height)
            )
        }
        return CGSize(width: designSize.width * scale, height: designSize.height * scale)
    }

    /// The center of a collapsed island may be a physical camera cutout.
    /// A minimal leaf gets only the right display wing; compact rows retain
    /// both wings and their authored spacer. Dimensions remain Host-owned.
    public static func collapsedRegionSize(
        for mode: ActivityPresentation.Mode,
        shellSize: CGSize,
        reservedCenterWidth: CGFloat
    ) -> CGSize {
        guard shellSize.width.isFinite, shellSize.height.isFinite,
              reservedCenterWidth.isFinite else { return .zero }
        let width = max(0, shellSize.width)
        let height = max(0, shellSize.height)
        guard mode == .minimal else { return CGSize(width: width, height: height) }
        return CGSize(width: max(0, width - max(0, reservedCenterWidth)) / 2, height: height)
    }

    static func resolvedNode(in presentation: ActivityPresentation, for mode: ActivityPresentation.Mode) -> IslandNode {
        let node = presentation.resolvedNode(for: mode)
        return ActivityPresentation.HostPolicy.accepts(node, for: mode)
            ? node : .text(.init("Activity"))
    }

    private var fallbackSummary: some View {
        Text(safeSummaryTitle)
            .font(IslandDesignTokens.font(for: .caption, scale: layoutScale))
            .foregroundStyle(color(.primary))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(safeSummaryTitle)
    }

    private var safeSummaryTitle: String {
        let trimmed = presentation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var bounded = ""
        for character in trimmed {
            let part = String(character)
            guard bounded.utf8.count + part.utf8.count <= IslandNode.Limits.maxTextBytes else { break }
            bounded += part
        }
        return bounded.isEmpty ? "Activity" : bounded
    }

    private func color(_ token: IslandSemanticColorToken) -> Color {
        IslandDesignTokens.color(for: token, colorScheme: colorScheme, contrast: contrast)
    }

    private var nodeSpacing: CGFloat {
        IslandDesignTokens.spacing(.xs, scale: layoutScale)
    }

    private var iconSide: CGFloat { scaled(mode == .expanded ? 20 : 16) }

    private func scaled(_ designPoints: CGFloat) -> CGFloat { designPoints * layoutScale }

    /// Native controls have discrete AppKit sizes. Pick their native drawing
    /// size rather than magnifying a composited control image.
    private var nativeControlSize: ControlSize {
        if layoutScale >= 1.5 { return .regular }
        return layoutScale > 1.05 ? .small : .mini
    }

    private var nativeProgressControlSize: ControlSize {
        layoutScale >= 1.5 ? .large : .regular
    }

    private func renderedNode(_ node: IslandNode, depth: Int) -> AnyView {
        guard depth <= IslandNode.Limits.maxDepth else { return AnyView(fallbackSummary) }
        switch node {
        case .text(let value):
            return AnyView(Text(value.content)
                .font(IslandDesignTokens.font(for: mode == .expanded ? .body : .caption, scale: layoutScale))
                .foregroundStyle(color(value.color))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityLabel(value.content))
        case .countdown(let value):
            return AnyView(IslandCountdownNodeView(reference: value, mode: mode,
                                                  tint: color(value.color), isVisible: isVisible,
                                                  resolve: countdownResolver, clock: displayClock))
        case .icon(let value):
            let isCompactWaveform = mode == .compact && value.symbolName == "waveform"
            return AnyView(Image(systemName: value.symbolName)
                .font(IslandDesignTokens.font(for: .headline, scale: layoutScale))
                .foregroundStyle(isCompactWaveform ? color(.success) : color(.accent))
                .frame(width: iconSide, height: iconSide)
                .symbolEffect(.variableColor, options: .repeating,
                              isActive: isCompactWaveform && !reduceMotion)
                .accessibilityLabel(accessibleIdentifier(value.symbolName)))
        case .image(let value):
            return AnyView(renderedImage(value))
        case .hStack(let stack):
            return AnyView(HStack(spacing: nodeSpacing) {
                ForEach(stack.children.indices, id: \.self) { index in
                    renderedNode(stack.children[index], depth: depth + 1)
                }
            })
        case .vStack(let stack):
            return AnyView(VStack(alignment: .leading, spacing: nodeSpacing) {
                ForEach(stack.children.indices, id: \.self) { index in
                    renderedNode(stack.children[index], depth: depth + 1)
                }
            })
        case .zStack(let stack):
            return AnyView(ZStack {
                ForEach(stack.children.indices, id: \.self) { index in
                    renderedNode(stack.children[index], depth: depth + 1)
                }
            })
        case .spacer:
            return AnyView(Spacer(minLength: 0))
        case .divider:
            return AnyView(Divider().overlay(color(.secondary).opacity(0.6)))
        case .progress(let value):
            switch value.style {
            case .linear:
                return AnyView(ProgressView(value: value.value)
                    .progressViewStyle(.linear)
                    .controlSize(nativeProgressControlSize)
                    .frame(height: scaled(20))
                    .tint(color(value.color))
                    .accessibilityLabel("Progress")
                    .accessibilityValue("\(Int((value.value * 100).rounded())) percent"))
            case .battery:
                return AnyView(BatteryProgressView(
                    value: value.value,
                    colorToken: value.color,
                    mode: mode
                ))
            }
        case .button(let value):
            return AnyView(SwiftUI.Button {
                onAction(.init(actionID: value.actionID, value: .none))
            } label: {
                if case .icon(let icon) = value.label {
                    Image(systemName: icon.symbolName)
                        .font(.system(size: scaled(12), weight: .semibold))
                        .foregroundStyle(color(.primary))
                        .frame(width: scaled(28), height: scaled(28))
                        .background(Circle().fill(color(.primary).opacity(
                            hoveredActionID == value.actionID ? 0.18 : 0.08
                        )))
                        .contentShape(Circle())
                } else {
                    renderedNode(value.label, depth: depth + 1)
                        .frame(minWidth: scaled(28), minHeight: scaled(28))
                        .padding(.horizontal, IslandDesignTokens.spacing(.xs, scale: layoutScale))
                        .background(
                            RoundedRectangle(cornerRadius: IslandDesignTokens.cornerRadius(.sm, scale: layoutScale))
                                .fill(color(.primary).opacity(hoveredActionID == value.actionID ? 0.18 : 0.08))
                        )
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .onHover { hoveredActionID = $0 ? value.actionID : nil }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: hoveredActionID)
            .accessibilityLabel(value.accessibilityLabel ?? accessibleLabel(for: value.label)))
        case .toggle(let value):
            return AnyView(SwiftUI.Toggle(isOn: Binding(
                get: { toggleValues[value.actionID] ?? value.isOn },
                set: { newValue in
                    toggleValues[value.actionID] = newValue
                    onAction(.init(actionID: value.actionID, value: .toggle(newValue)))
                }
            )) {
                Text(value.title)
                    .font(IslandDesignTokens.font(for: .body, scale: layoutScale))
                    .foregroundStyle(color(.primary))
                    .lineLimit(1)
            }
            .toggleStyle(.switch)
            .controlSize(nativeControlSize)
            .tint(color(.accent))
            .frame(minHeight: scaled(28))
            .accessibilityLabel(value.title))
        case .slider(let value):
            return AnyView(VStack(alignment: .leading, spacing: IslandDesignTokens.spacing(.xs, scale: layoutScale)) {
                if value.showsTitle {
                    Text(value.title)
                        .font(IslandDesignTokens.font(for: .caption, scale: layoutScale))
                        .foregroundStyle(color(.primary))
                        .lineLimit(1)
                }
                SwiftUI.Slider(value: Binding(
                    get: { sliderInteraction.displayedValue(for: value.actionID, fallback: value.value) },
                    set: { newValue in
                        let bounded = sliderInteraction.update(
                            value.actionID, value: newValue, fallback: value.value
                        )
                        onAction(.init(actionID: value.actionID, value: .slider(bounded)))
                    }
                ), in: 0...1, onEditingChanged: { isEditing in
                    if isEditing {
                        sliderInteraction.beginEditing(value.actionID)
                    } else {
                        let committed = sliderInteraction.endEditing(value.actionID, fallback: value.value)
                        onAction(.init(actionID: value.actionID, value: .sliderCommit(committed)))
                    }
                })
                .controlSize(nativeControlSize)
                .frame(height: scaled(12))
                .tint(color(.accent))
                .accessibilityLabel(value.title)
            })
        }
    }

    @ViewBuilder
    private func renderedImage(_ value: IslandNode.Image) -> some View {
        let side = IslandDesignTokens.imageSide(value.size, mode: mode, scale: layoutScale)
        let radius: CGFloat = switch value.size {
        case .icon: 0
        case .thumbnail: scaled(3)
        case .artwork: IslandDesignTokens.cornerRadius(.md, scale: layoutScale)
        }
        switch value.source {
        case .systemSymbol(let name):
            Image(systemName: name)
                .resizable()
                .scaledToFit()
                .foregroundStyle(color(.accent))
                .frame(width: side, height: side)
                .accessibilityLabel(accessibleIdentifier(name))
        case .pluginAsset, .brokerResource:
            if let image = imageResolver(value.source) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: value.size == .artwork ? .fill : .fit)
                    .frame(width: side, height: side)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .accessibilityLabel("Image")
            } else if value.size != .icon {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color.white.opacity(0.09))
                    Image(systemName: "music.note")
                        .font(.system(size: max(scaled(10), side * 0.25), weight: .semibold))
                        .foregroundStyle(color(.secondary).opacity(0.65))
                }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: scaled(0.5))
                }
                .accessibilityLabel("Image unavailable")
            } else {
                Image(systemName: "photo")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(color(.secondary))
                    .frame(width: side, height: side)
                    .accessibilityLabel("Image unavailable")
            }
        }
    }

    private func accessibleLabel(for node: IslandNode) -> String {
        switch node {
        case .text(let value): return value.content
        case .countdown: return "Countdown"
        case .icon(let value): return accessibleIdentifier(value.symbolName)
        case .image: return "Image"
        case .hStack(let stack), .vStack(let stack), .zStack(let stack):
            return stack.children.map(accessibleLabel).filter { !$0.isEmpty }.joined(separator: " ")
        case .button(let value): return accessibleLabel(for: value.label)
        case .toggle(let value): return value.title
        case .slider(let value): return value.title
        case .progress(let value): return value.style == .battery ? "Battery level" : "Progress"
        case .spacer, .divider: return ""
        }
    }

    private func accessibleIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }
}
