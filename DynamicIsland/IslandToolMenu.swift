import AppKit
import SwiftUI

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
        let button = ToolButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        button.title = ""
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.image = NSImage(systemSymbolName: "alarm.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        button.image?.isTemplate = true
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
            coordinator?.cancelActiveMenu()
        }
        context.coordinator.update(self, button: button,
                                   enabled: isEnabled && context.environment.isEnabled)
        return button
    }

    func updateNSView(_ button: ToolButton, context: Context) {
        context.coordinator.update(self, button: button,
                                   enabled: isEnabled && context.environment.isEnabled)
    }

    static func dismantleNSView(_ button: ToolButton, coordinator: Coordinator) {
        coordinator.invalidate()
        button.onWindowDetached = nil
        button.target = nil
        button.action = nil
    }

    @MainActor
    final class ToolButton: NSButton {
        var onWindowDetached: (@MainActor () -> Void)?

        override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { onWindowDetached?() }
        }

        func applySelectionStyle(_ selected: Bool) {
            contentTintColor = .white.withAlphaComponent(selected ? 1 : 0.68)
            wantsLayer = true
            layer?.cornerRadius = 14
            layer?.backgroundColor = NSColor.white.withAlphaComponent(selected ? 0.18 : 0.08).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(selected ? 0.22 : 0.08).cgColor
            layer?.borderWidth = 0.5
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        @MainActor
        private final class Session {
            let token: UUID
            let entries: [Entry]
            let onEnded: @MainActor (UUID) -> Void
            let onCancelled: @MainActor (UUID) -> Void
            let isCurrent: @MainActor (UUID) -> Bool
            let menu: NSMenu
            var didOpen = false
            var didClose = false
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

        func update(_ configuration: IslandToolMenu, button: ToolButton, enabled: Bool) {
            guard !isInvalidated else { return }
            self.configuration = configuration
            self.button = button
            self.enabled = enabled
            button.isEnabled = enabled
            button.applySelectionStyle(configuration.isSelected)
            // Updating selection styling or the next menu's snapshots must not
            // mutate the menu currently being tracked by AppKit.
            if !enabled { cancelActiveMenu() }
        }

        @objc func openMenu(_ sender: NSButton) {
            guard !isInvalidated, enabled, activeSession == nil,
                  let button, sender === button, button.window != nil,
                  let configuration, !configuration.entries.isEmpty else { return }

            let menu = makeMenu(entries: configuration.entries)
            // Acquire before entering AppKit's nested tracking loop. A Host that
            // has hidden/collapsed the island can refuse this interaction.
            guard let token = configuration.onTrackingBegan() else { return }
            let session = Session(token: token, configuration: configuration, menu: menu)
            guard !isInvalidated, enabled, button.window != nil,
                  session.isCurrent(token) else {
                session.onCancelled(token)
                return
            }
            activeSession = session
            menu.delegate = self

            // NSMenu confines itself to the screen and supplies native scrolling,
            // keyboard navigation, Escape, and outside-click cancellation.
            _ = menu.popUp(positioning: nil,
                           at: NSPoint(x: button.bounds.minX, y: button.bounds.minY - 4),
                           in: button)
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
            guard canComplete(session) else {
                cancelActiveMenu()
                return
            }
            // menuDidClose may precede the item's action. Keep the snapshot and
            // defer its selection until popUp has returned, with the hold intact.
            session.pendingSelection = session.entries[index.intValue]
        }

        func menuWillOpen(_ menu: NSMenu) {
            guard let session = activeSession, session.menu === menu else { return }
            session.didOpen = true
        }

        func menuDidClose(_ menu: NSMenu) {
            guard let session = activeSession, session.menu === menu else { return }
            session.didClose = true
        }

        private func canComplete(_ session: Session) -> Bool {
            !isInvalidated && enabled && activeSession === session
                && button?.window != nil && session.isCurrent(session.token)
        }

        private func finish(_ session: Session) {
            guard activeSession === session else { return }
            guard canComplete(session), session.didOpen, session.didClose else {
                cancelActiveMenu()
                return
            }
            session.pendingSelection?.onSelect()
            // Selection can synchronously hide or dismantle the host view.
            guard activeSession === session else { return }
            guard canComplete(session) else {
                cancelActiveMenu()
                return
            }
            activeSession = nil
            session.menu.delegate = nil
            session.pendingSelection = nil
            session.onEnded(session.token)
        }

        func cancelActiveMenu() {
            guard let session = activeSession else { return }
            // Clear first: cancelTracking and Host callbacks can reenter through
            // SwiftUI dismantling or the native menu delegate.
            activeSession = nil
            session.pendingSelection = nil
            session.menu.delegate = nil
            session.menu.cancelTracking()
            session.onCancelled(session.token)
        }

        func invalidate() {
            guard !isInvalidated else { return }
            isInvalidated = true
            enabled = false
            configuration = nil
            cancelActiveMenu()
            button = nil
        }
    }
}
