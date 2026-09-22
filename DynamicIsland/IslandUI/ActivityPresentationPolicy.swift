import Foundation

/// Host-side presentation resolution and layout limits. None of these values
/// cross the serialized Activity boundary.
public extension ActivityPresentation {
    /// Resolve only toward a simpler supplied layout. An expanded tree is
    /// never squeezed into a compact or minimal shell. The summary is the last
    /// fallback and also supports JSON written before declarative layouts.
    func resolvedNode(for mode: Mode) -> IslandNode {
        let candidates: [(IslandNode?, Mode)]
        switch mode {
        case .minimal: candidates = [(minimal, .minimal)]
        case .compact: candidates = [(compact, .compact), (minimal, .minimal)]
        case .expanded: candidates = [(expanded, .expanded), (compact, .compact), (minimal, .minimal)]
        }
        for (candidate, authoredMode) in candidates {
            if let candidate, HostPolicy.accepts(candidate, for: authoredMode),
               HostPolicy.accepts(candidate, for: mode) {
                return candidate
            }
        }
        return summaryNode(for: mode)
    }

    private func summaryNode(for mode: Mode) -> IslandNode {
        let icon = symbolName.flatMap { name -> IslandNode? in
            let node = IslandNode.icon(.init(name))
            return (try? node.validate()) != nil ? node : nil
        }
        if mode == .minimal {
            return icon ?? .text(.init(Self.shortened(title, maxBytes: 40)))
        }

        var row: [IslandNode] = []
        if let icon { row.append(icon) }
        row.append(.text(.init(Self.shortened(title, maxBytes: mode == .compact ? 80 : 128))))
        let heading: IslandNode = .hStack(.init(row))
        if mode == .compact { return heading }

        var rows: [IslandNode] = [heading]
        if let subtitle, !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rows.append(.text(.init(Self.shortened(subtitle, maxBytes: 128))))
        }
        if let progress, progress.isFinite, (0...1).contains(progress) {
            rows.append(.progress(.init(progress)))
        }
        return .vStack(.init(rows))
    }

    private static func shortened(_ value: String, maxBytes: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        for character in trimmed {
            let part = String(character)
            guard result.utf8.count + part.utf8.count <= maxBytes else { break }
            result += part
        }
        return result.isEmpty ? "Activity" : result
    }

    /// Host-owned limits for each display form. T12's renderer must also
    /// measure and clip the actual SwiftUI view within its allocated height.
    /// In particular, the existing 200 pt shell leaves 140 pt after its 60 pt
    /// switcher/padding, while the 190 pt timer shell leaves 130 pt.
    enum HostPolicy {
        public static var maximumExpandedShellHeight: Double { Double(IslandVisualStyle.expandedShellSize.height) }
        public static var expandedChromeHeight: Double {
            Double(2 * IslandVisualStyle.expandedContentPadding
                + IslandVisualStyle.expandedSurfaceSwitcherHeight
                + IslandVisualStyle.expandedSurfaceSpacing)
        }

        public static func expandedContentHeight(forHostShellHeight height: Double) -> Double {
            guard height.isFinite else { return 0 }
            return max(0, min(height, maximumExpandedShellHeight) - expandedChromeHeight)
        }

        public static func accepts(_ node: IslandNode, for mode: Mode) -> Bool {
            guard (try? node.validate()) != nil else { return false }
            let metrics = Metrics(node)
            guard metrics.hasVisibleContent, metrics.verticalRows > 0 else { return false }
            switch mode {
            case .minimal:
                switch node {
                case .text, .icon, .image: break
                default: return false
                }
                return metrics.nodeCount <= 1 && metrics.depth <= 1 && metrics.textBytes <= 40
            case .compact:
                return metrics.nodeCount <= 8 && metrics.depth <= 3
                    && metrics.maxChildren <= 4 && metrics.verticalRows <= 1
                    && metrics.textBytes <= 96 && metrics.actionCount <= 1
                    && !metrics.hasExpandedOnlyControl
            case .expanded:
                return metrics.nodeCount <= 32 && metrics.depth <= 5
                    && metrics.maxChildren <= 8 && metrics.verticalRows <= 5
                    && metrics.textBytes <= 512 && metrics.actionCount <= 4
            }
        }

        private struct Metrics {
            var nodeCount = 1
            var depth = 1
            var maxChildren = 0
            var verticalRows = 1
            var textBytes = 0
            var actionCount = 0
            var hasExpandedOnlyControl = false
            var hasVisibleContent = false

            init(_ node: IslandNode) {
                switch node {
                case .text(let value):
                    textBytes = value.content.utf8.count
                    hasVisibleContent = !value.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .icon, .image, .progress:
                    hasVisibleContent = true
                case .spacer, .divider: break
                case .hStack(let stack), .zStack(let stack):
                    merge(stack.children, vertical: false)
                case .vStack(let stack):
                    merge(stack.children, vertical: true)
                case .button(let value):
                    let label = Metrics(value.label)
                    mergeChild(label)
                    verticalRows = label.verticalRows
                    actionCount += 1
                case .toggle(let value):
                    textBytes = value.title.utf8.count
                    actionCount = 1
                    hasExpandedOnlyControl = true
                    hasVisibleContent = true
                case .slider(let value):
                    textBytes = value.title.utf8.count
                    actionCount = 1
                    verticalRows = 2
                    hasExpandedOnlyControl = true
                    hasVisibleContent = true
                }
            }

            private mutating func merge(_ children: [IslandNode], vertical: Bool) {
                maxChildren = children.count
                verticalRows = vertical ? 0 : (children.isEmpty ? 0 : 1)
                for child in children {
                    let metrics = Metrics(child)
                    mergeChild(metrics)
                    if vertical { verticalRows += metrics.verticalRows }
                    else { verticalRows = max(verticalRows, metrics.verticalRows) }
                }
            }

            private mutating func mergeChild(_ child: Metrics) {
                nodeCount += child.nodeCount
                depth = max(depth, child.depth + 1)
                maxChildren = max(maxChildren, child.maxChildren)
                textBytes += child.textBytes
                actionCount += child.actionCount
                hasExpandedOnlyControl = hasExpandedOnlyControl || child.hasExpandedOnlyControl
                hasVisibleContent = hasVisibleContent || child.hasVisibleContent
            }
        }
    }
}
