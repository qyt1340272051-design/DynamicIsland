import AppKit
import OSLog
import SwiftUI

@MainActor
enum IslandToolMenuTrace {
    private static let logger = Logger(subsystem: "com.rong5.dynamic-island", category: "ToolMenu")

    static func record(event: String, session: UUID,
                       pointerInside: Bool? = nil, hovering: Bool? = nil) {
        let pointer = pointerInside.map { $0 ? "true" : "false" } ?? "-"
        let hover = hovering.map { $0 ? "true" : "false" } ?? "-"
        logger.info("event=\(event, privacy: .public) session=\(session.uuidString, privacy: .public) pointerInside=\(pointer, privacy: .public) hovering=\(hover, privacy: .public)")
    }
}

/// Once tracking ends, the VM owns the bounded return period. Selection may
/// rebuild the native control, so its lifetime must no longer own that hold.
@MainActor
enum IslandToolMenuCompletion {
    static func complete(session: UUID,
                         onEnded: @MainActor (UUID) -> Void,
                         isCurrent: @MainActor (UUID) -> Bool,
                         selection: (@MainActor () -> Void)?) {
        IslandToolMenuTrace.record(event: "native.end", session: session)
        onEnded(session)
        // A real hide, drag, or Host interruption revokes the token. A normal
        // replacement of the old SwiftUI/AppKit control does not revoke it.
        guard isCurrent(session) else {
            IslandToolMenuTrace.record(event: "native.selection.sessionInvalid", session: session)
            return
        }
        guard let selection else { return }
        IslandToolMenuTrace.record(event: "native.selection", session: session)
        selection()
    }
}

/// Keeps the Host's tool-selection hold alive for AppKit's entire tracking loop.
/// The first entry is the built-in timer; subsequent entries are plugin snapshots.
@MainActor
struct IslandToolMenu: NSViewRepresentable {
    struct Entry {
        let id: String
        let title: String
        let symbolName: String
        let onSelect: @MainActor () -> Void
    }

    let entries: [Entry]
    let isSelected: Bool
    var isEnabled = true
    let onTrackingBegan: @MainActor () -> UUID?
    let onTrackingEnded: @MainActor (UUID) -> Void
    let onTrackingCancelled: @MainActor (UUID) -> Void
    let onSessionIsCurrent: @MainActor (UUID) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ToolButton {
        let size = 28 * context.environment.islandLayoutScale
        let button = ToolButton(frame: NSRect(x: 0, y: 0, width: size, height: size))
        button.title = ""
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = "计时与插件工具"
        button.setAccessibilityLabel("计时")
        button.setAccessibilityHelp("计时与插件工具")
        button.setAccessibilityIdentifier("island-tool-selector")
        button.identifier = .init("island-tool-selector")
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        button.target = context.coordinator
        button.action = #selector(Coordinator.openMenu(_:))
        button.onWindowDetached = { [weak coordinator = context.coordinator] in
            coordinator?.cancelActiveMenu(reason: .windowDetached)
        }
        context.coordinator.update(self, button: button,
                                   enabled: isEnabled && context.environment.isEnabled,
                                   layoutScale: context.environment.islandLayoutScale)
        return button
    }

    func updateNSView(_ button: ToolButton, context: Context) {
        context.coordinator.update(self, button: button,
                                   enabled: isEnabled && context.environment.isEnabled,
                                   layoutScale: context.environment.islandLayoutScale)
    }

    static func dismantleNSView(_ button: ToolButton, coordinator: Coordinator) {
        coordinator.invalidate(reason: .dismantle)
        button.onWindowDetached = nil
        button.target = nil
        button.action = nil
    }

    @MainActor
    final class ToolButton: NSButton {
        var onWindowDetached: (@MainActor () -> Void)?
        private(set) var layoutScale: CGFloat = 1

        override var intrinsicContentSize: NSSize {
            NSSize(width: 28 * layoutScale, height: 28 * layoutScale)
        }

        // A borderless NSButton still has AppKit alignment insets. The root's
        // explicit frame and this native hit region must use the same bounds.
        override var alignmentRectInsets: NSEdgeInsets {
            NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }

        func applyLayoutScale(_ scale: CGFloat) {
            let resolvedScale = scale.isFinite && scale > 0 ? scale : 1
            guard layoutScale != resolvedScale || image == nil else { return }
            layoutScale = resolvedScale
            invalidateIntrinsicContentSize()
            setFrameSize(intrinsicContentSize)
            // Request the symbol at its final point size so AppKit draws it at
            // the window's backing scale instead of enlarging a cached bitmap.
            image = NSImage(systemSymbolName: "alarm.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12 * layoutScale, weight: .semibold))
            image?.isTemplate = true
            needsDisplay = true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { onWindowDetached?() }
        }

        func applySelectionStyle(_ selected: Bool) {
            contentTintColor = .white.withAlphaComponent(selected ? 1 : 0.68)
            wantsLayer = true
            layer?.cornerRadius = 14 * layoutScale
            layer?.backgroundColor = NSColor.white.withAlphaComponent(selected ? 0.18 : 0.08).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(selected ? 0.22 : 0.08).cgColor
            layer?.borderWidth = 0.5 * layoutScale
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        enum CancellationReason: String {
            case updateDisabled, windowDetached, dismantle, invalidate, sessionInvalid
        }

        @MainActor
        private final class Session {
            let token: UUID
            let entries: [Entry]
            let onEnded: @MainActor (UUID) -> Void
            let onCancelled: @MainActor (UUID) -> Void
            let isCurrent: @MainActor (UUID) -> Bool
            let menu: NSMenu
            var didOpen = false
            var pendingSelection: Entry?

            init(token: UUID, configuration: IslandToolMenu, menu: NSMenu) {
                self.token = token
                entries = configuration.entries
                onEnded = configuration.onTrackingEnded
                onCancelled = configuration.onTrackingCancelled
                isCurrent = configuration.onSessionIsCurrent
                self.menu = menu
            }
        }

        private weak var button: ToolButton?
        private var configuration: IslandToolMenu?
        private var activeSession: Session?
        private var enabled = false
        private var isInvalidated = false

        func update(_ configuration: IslandToolMenu, button: ToolButton, enabled: Bool,
                    layoutScale: CGFloat) {
            guard !isInvalidated else { return }
            self.configuration = configuration
            self.button = button
            self.enabled = enabled
            button.isEnabled = enabled
            button.applyLayoutScale(layoutScale)
            button.applySelectionStyle(configuration.isSelected)
            // Updating selection styling or the next menu's snapshots must not
            // mutate the menu currently being tracked by AppKit.
            if !enabled { cancelActiveMenu(reason: .updateDisabled) }
        }

        @objc func openMenu(_ sender: NSButton) {
            guard !isInvalidated, enabled, activeSession == nil,
                  let button, sender === button, button.window != nil,
                  let configuration, !configuration.entries.isEmpty else { return }

            let menu = makeMenu(entries: configuration.entries)
            // Acquire before entering AppKit's nested tracking loop. A Host that
            // has hidden/collapsed the island can refuse this interaction.
            guard let token = configuration.onTrackingBegan() else { return }
            IslandToolMenuTrace.record(event: "native.begin", session: token)
            let session = Session(token: token, configuration: configuration, menu: menu)
            guard !isInvalidated, enabled, button.window != nil,
                  session.isCurrent(token) else {
                IslandToolMenuTrace.record(event: "native.cancel.sessionInvalid", session: token)
                session.onCancelled(token)
                return
            }
            activeSession = session
            menu.delegate = self

            // NSMenu confines itself to the screen and supplies native scrolling,
            // keyboard navigation, Escape, and outside-click cancellation.
            let selected = menu.popUp(positioning: nil,
                                      at: NSPoint(x: button.bounds.minX,
                                                  y: button.bounds.minY - 4 * button.layoutScale),
                                      in: button)
            IslandToolMenuTrace.record(event: selected ? "native.popUpReturn.selected" : "native.popUpReturn.cancelled",
                                      session: token)
            finish(session)
        }

        private func makeMenu(entries: [Entry]) -> NSMenu {
            let menu = NSMenu(title: "计时与插件工具")
            menu.autoenablesItems = false
            for (index, entry) in entries.enumerated() {
                if index == 1 { menu.addItem(.separator()) }
                let item = NSMenuItem(title: entry.title,
                                      action: #selector(chooseItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = NSNumber(value: index)
                item.identifier = .init(entry.id)
                item.setAccessibilityIdentifier(entry.id)
                item.image = NSImage(systemSymbolName: entry.symbolName, accessibilityDescription: nil)
                menu.addItem(item)
            }
            return menu
        }

        @objc private func chooseItem(_ item: NSMenuItem) {
            guard let session = activeSession, item.menu === session.menu,
                  let index = item.representedObject as? NSNumber,
                  session.entries.indices.contains(index.intValue) else { return }
            IslandToolMenuTrace.record(event: "native.choose", session: session.token)
            guard canComplete(session) else {
                cancelActiveMenu(reason: .sessionInvalid)
                return
            }
            // menuDidClose may precede the item's action. Keep the snapshot and
            // defer its selection until popUp returns and the VM owns the hold.
            session.pendingSelection = session.entries[index.intValue]
        }

        func menuWillOpen(_ menu: NSMenu) {
            guard let session = activeSession, session.menu === menu else { return }
            session.didOpen = true
            IslandToolMenuTrace.record(event: "native.willOpen", session: session.token)
        }

        func menuDidClose(_ menu: NSMenu) {
            guard let session = activeSession, session.menu === menu else { return }
            IslandToolMenuTrace.record(event: "native.didClose", session: session.token)
        }

        private func canComplete(_ session: Session) -> Bool {
            !isInvalidated && enabled && activeSession === session
                && button?.window != nil && session.isCurrent(session.token)
        }

        private func finish(_ session: Session) {
            IslandToolMenuTrace.record(event: "native.finish", session: session.token)
            guard activeSession === session else { return }
            // popUp returning is the tracking boundary; do not require a
            // delegate/action callback order that AppKit does not guarantee.
            guard canComplete(session), session.didOpen else {
                cancelActiveMenu(reason: .sessionInvalid)
                return
            }
            let selection = session.pendingSelection?.onSelect
            // Transfer ownership before callbacks can publish new content and
            // synchronously detach or dismantle this native control.
            activeSession = nil
            session.menu.delegate = nil
            session.pendingSelection = nil
            IslandToolMenuCompletion.complete(session: session.token,
                                              onEnded: session.onEnded,
                                              isCurrent: session.isCurrent,
                                              selection: selection)
        }

        func cancelActiveMenu(reason: CancellationReason = .sessionInvalid) {
            guard let session = activeSession else { return }
            IslandToolMenuTrace.record(event: "native.cancel.\(reason.rawValue)", session: session.token)
            // Clear first: cancelTracking and Host callbacks can reenter through
            // SwiftUI dismantling or the native menu delegate.
            activeSession = nil
            session.pendingSelection = nil
            session.menu.delegate = nil
            session.menu.cancelTracking()
            session.onCancelled(session.token)
        }

        func invalidate(reason: CancellationReason = .invalidate) {
            guard !isInvalidated else { return }
            if let session = activeSession {
                IslandToolMenuTrace.record(event: "native.invalidate", session: session.token)
            }
            isInvalidated = true
            enabled = false
            configuration = nil
            cancelActiveMenu(reason: reason)
            button = nil
        }
    }
}
