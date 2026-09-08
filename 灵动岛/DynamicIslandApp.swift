import AppKit
import SwiftUI

@main
struct DynamicIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panelController: IslandPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSClassFromString("XCTestCase") == nil else {
            return
        }

        NSApp.setActivationPolicy(.accessory)

        let viewModel = IslandViewModel()
        let panelController = IslandPanelController(viewModel: viewModel)
        self.panelController = panelController
        panelController.show()
        configureStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController?.hide()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.tophalf.filled", accessibilityDescription: "灵动岛")
        item.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示灵动岛", action: #selector(showIsland), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "隐藏灵动岛", action: #selector(hideIsland), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
    }

    @objc private func showIsland() {
        panelController?.show()
    }

    @objc private func hideIsland() {
        panelController?.hide()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
