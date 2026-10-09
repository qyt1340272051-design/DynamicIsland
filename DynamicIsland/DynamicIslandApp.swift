import AppKit
import OSLog
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
    private var screenManager: ScreenManager?
    private var viewModel: IslandViewModel?
    private let diagnosticReportService = DiagnosticReportService()
    private var statusFeedbackTask: Task<Void, Never>?
    private var pluginManager: PluginManager?
    private var pluginEnvironment: PluginLifecycleEnvironment?
    private var pluginStartupTask: Task<Void, Never>?
    private var pluginLifecycle: PluginLifecycleBridge?
    private let pluginLogger = Logger(subsystem: "DynamicIsland", category: "PluginLifecycle")
#if DEBUG
    private var screenSimulatorWindowController: ScreenSimulatorWindowController?
    private var activityDebugWindowController: ActivityDebugWindowController?
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSClassFromString("XCTestCase") == nil else {
            return
        }

        NSApp.setActivationPolicy(.accessory)

        let viewModel = IslandViewModel()
        let screenManager = ScreenManager()
        let batteryService = IOKitBatteryService()
        let activityRuntime = IslandActivityRuntime(
            viewModel: viewModel,
            batteryService: batteryService
        )
        let panelController = IslandPanelController(
            viewModel: viewModel,
            screenManager: screenManager,
            activityRuntime: activityRuntime
        )
        self.viewModel = viewModel
        self.screenManager = screenManager
        self.panelController = panelController
        configurePlugins(lifecycle: activityRuntime.pluginLifecycle, batteryService: batteryService)
        panelController.show()
        configureStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusFeedbackTask?.cancel()
        pluginStartupTask?.cancel()
        pluginEnvironment?.stop()
        pluginLifecycle?.shutdown()
        panelController?.hide()
    }

    private func configurePlugins(lifecycle: PluginLifecycleBridge, batteryService: any BatteryService) {
        pluginLifecycle = lifecycle
        pluginEnvironment = PluginLifecycleEnvironment(batteryService: batteryService) { [weak lifecycle] state in
            lifecycle?.setEnvironment(isSleeping: state.isSleeping, isLowBattery: state.isLowBattery)
        }
        do {
            // Plugin Host compatibility is the 0.6.0 development contract.
            // Distribution metadata is updated by the release task separately.
            let configuration = try PluginManagerConfiguration.applicationSupport(
                hostVersion: SemanticVersion("0.6.0")
            )
            let manager = PluginManager(configuration: configuration, lifecycleHandler: lifecycle)
            pluginManager = manager
            pluginStartupTask = Task { [pluginLogger] in
                let report = await manager.discover()
                for failure in report.failures {
                    pluginLogger.error("Plugin discovery rejected a candidate: \(failure.error.code, privacy: .public)")
                }
            }
        } catch {
            pluginLogger.error("Plugin Host directory could not be configured.")
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.tophalf.filled", accessibilityDescription: "Dynamic Island")
        item.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示 Dynamic Island", action: #selector(showIsland), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "隐藏 Dynamic Island", action: #selector(hideIsland), keyEquivalent: ""))
        menu.addItem(.separator())

        let diagnosticsItem = NSMenuItem(
            title: "复制调试信息",
            action: #selector(copyDiagnosticInfo),
            keyEquivalent: ""
        )
        diagnosticsItem.image = NSImage(
            systemSymbolName: "doc.on.clipboard",
            accessibilityDescription: "复制调试信息"
        )
        menu.addItem(diagnosticsItem)

        let feedbackItem = NSMenuItem(
            title: "提交 Beta 反馈...",
            action: #selector(openBetaFeedback),
            keyEquivalent: ""
        )
        feedbackItem.image = NSImage(
            systemSymbolName: "exclamationmark.bubble",
            accessibilityDescription: "提交 Beta 反馈"
        )
        menu.addItem(feedbackItem)
#if DEBUG
        menu.addItem(.separator())
        let simulatorItem = NSMenuItem(title: "屏幕模拟器...", action: #selector(showScreenSimulator), keyEquivalent: "")
        simulatorItem.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "屏幕模拟器")
        menu.addItem(simulatorItem)
        let activityDebugItem = NSMenuItem(title: "Activity Debug...", action: #selector(showActivityDebug), keyEquivalent: "")
        activityDebugItem.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Activity Debug")
        menu.addItem(activityDebugItem)
#endif
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

    @objc private func copyDiagnosticInfo() {
        guard let screenManager, let viewModel else {
            showStatusFeedback(succeeded: false)
            return
        }

        screenManager.refresh()
        let succeeded = diagnosticReportService.makeAndCopyReport(
            screenManager: screenManager,
            viewModel: viewModel,
            panelFrame: panelController?.diagnosticPanelFrame,
            isPanelVisible: panelController?.isPanelVisible ?? false
        )
        showStatusFeedback(succeeded: succeeded)
    }

    @objc private func openBetaFeedback() {
        let succeeded = NSWorkspace.shared.open(BetaFeedbackConfiguration.issueURL)
        if !succeeded {
            showStatusFeedback(succeeded: false)
        }
    }

#if DEBUG
    @objc private func showScreenSimulator() {
        guard let screenManager else {
            return
        }

        let controller = screenSimulatorWindowController
            ?? ScreenSimulatorWindowController(screenManager: screenManager)
        screenSimulatorWindowController = controller
        controller.present()
    }

    @objc private func showActivityDebug() {
        let controller = activityDebugWindowController ?? ActivityDebugWindowController()
        activityDebugWindowController = controller
        controller.present()
    }
#endif

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showStatusFeedback(succeeded: Bool) {
        guard let button = statusItem?.button else {
            return
        }

        if !succeeded {
            NSSound.beep()
        }

        button.image = NSImage(
            systemSymbolName: succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
            accessibilityDescription: succeeded ? "调试信息已复制" : "操作失败"
        )
        button.toolTip = succeeded ? "调试信息已复制" : "操作失败"

        statusFeedbackTask?.cancel()
        statusFeedbackTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let button = self?.statusItem?.button else {
                return
            }
            button.image = NSImage(
                systemSymbolName: "capsule.tophalf.filled",
                accessibilityDescription: "Dynamic Island"
            )
            button.toolTip = "Dynamic Island"
            self?.statusFeedbackTask = nil
        }
    }
}
