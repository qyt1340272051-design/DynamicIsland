import AppKit
import SwiftUI

/// Tool navigation stays inside the island. Overflow scrolls horizontally;
/// selecting an item never starts an AppKit menu-tracking session.
struct IslandToolTabs: View {
    struct Entry: Identifiable {
        let id: String
        let title: String
        let onSelect: @MainActor () -> Void
    }

    let entries: [Entry]
    let selectedID: String?
    @Environment(\.islandLayoutScale) private var layoutScale

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroll in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(entries) { entry in
                            Button(action: entry.onSelect) {
                                Text(entry.title)
                                    .font(.system(size: 11 * layoutScale, weight: .semibold))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .padding(.horizontal, 8 * layoutScale)
                                    .frame(minWidth: 52 * layoutScale, maxWidth: 132 * layoutScale)
                                    .frame(height: 24 * layoutScale)
                                    .contentShape(RoundedRectangle(cornerRadius: 5 * layoutScale))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(selectedID == entry.id ? 1 : 0.6))
                            .background(selectedID == entry.id ? Color.white.opacity(0.16) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5 * layoutScale))
                            .accessibilityLabel(entry.title)
                            .accessibilityAddTraits(selectedID == entry.id ? .isSelected : [])
                            .accessibilityIdentifier(entry.id)
                            .id(entry.id)
                        }
                    }
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5 * layoutScale))
                    .frame(minWidth: geometry.size.width, alignment: .center)
                }
                // `.hidden` still shows a scroller, and adds its height, when a mouse is connected.
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .onAppear { if let selectedID { scroll.scrollTo(selectedID, anchor: .center) } }
                .onChange(of: selectedID) { _, id in
                    if let id { scroll.scrollTo(id, anchor: .center) }
                }
            }
        }
        .frame(height: 24 * layoutScale)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("island-inline-tool-tabs")
        .islandPagingExcluded()
    }
}

/// Native icon controls keep final-point bounds and hit regions across display
/// scales, without installing a menu or holding the island open after a click.
struct IslandRegionButton: NSViewRepresentable {
    let title: String
    let symbolName: String
    let identifier: String
    let isSelected: Bool
    let onSelect: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NativeButton {
        let button = NativeButton(frame: .zero)
        button.title = ""
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectRegion)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: NativeButton, context: Context) {
        context.coordinator.onSelect = onSelect
        button.applyLayoutScale(context.environment.islandLayoutScale, symbolName: symbolName)
        button.isEnabled = context.environment.isEnabled
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier(identifier)
        button.identifier = .init(identifier)
        button.contentTintColor = .white.withAlphaComponent(isSelected ? 1 : 0.68)
        button.wantsLayer = true
        button.layer?.cornerRadius = 14 * button.layoutScale
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(isSelected ? 0.18 : 0.08).cgColor
        button.layer?.borderColor = NSColor.white.withAlphaComponent(isSelected ? 0.22 : 0.08).cgColor
        button.layer?.borderWidth = 0.5 * button.layoutScale
    }

    final class Coordinator: NSObject {
        var onSelect: (@MainActor () -> Void)?
        @objc func selectRegion() { onSelect?() }
    }

    final class NativeButton: NSButton {
        private(set) var layoutScale: CGFloat = 1
        private var renderedSymbolName: String?
        override var intrinsicContentSize: NSSize { .init(width: 28 * layoutScale, height: 28 * layoutScale) }
        override var alignmentRectInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }

        func applyLayoutScale(_ scale: CGFloat, symbolName: String) {
            let resolvedScale = scale.isFinite && scale > 0 ? scale : 1
            guard layoutScale != resolvedScale || renderedSymbolName != symbolName || image == nil else { return }
            layoutScale = resolvedScale
            renderedSymbolName = symbolName
            invalidateIntrinsicContentSize()
            setFrameSize(intrinsicContentSize)
            image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12 * layoutScale, weight: .semibold))
            image?.isTemplate = true
        }
    }
}
