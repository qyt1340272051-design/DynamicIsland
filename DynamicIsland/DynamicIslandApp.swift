import AppKit
import Combine
import OSLog
import SwiftUI

@main
struct DynamicIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            if let model = appDelegate.pluginExtensionsModel {
                PluginExtensionsView(model: model, onShowDiagnostics: { appDelegate.showPluginDiagnostics() })
            } else {
                ContentUnavailableView("插件管理暂不可用", systemImage: "puzzlepiece.extension",
                                       description: Text("请等待插件初始化完成。"))
                    .frame(width: 800, height: 600)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published fileprivate var pluginExtensionsModel: PluginExtensionsModel?
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
    private var activityRuntime: IslandActivityRuntime?
    private var pluginDiagnosticsModel: PluginDiagnosticsModel?
    private var pluginDiagnosticsWindowController: PluginDiagnosticsWindowController?
    private var pluginExtensionsWindowController: PluginExtensionsWindowController?
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
        self.activityRuntime = activityRuntime
        configurePlugins(lifecycle: activityRuntime.pluginLifecycle, diagnostics: activityRuntime.pluginDiagnostics,
                         permissions: activityRuntime.permissionManager,
                         batteryService: batteryService)
        panelController.show()
        configureStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusFeedbackTask?.cancel()
        pluginStartupTask?.cancel()
        pluginEnvironment?.stop()
        pluginDiagnosticsWindowController?.close()
        pluginExtensionsWindowController?.close()
        activityRuntime?.shutdownPlugins()
        panelController?.hide()
    }

    private func configurePlugins(lifecycle: PluginLifecycleBridge, diagnostics: PluginDiagnosticsStore,
                                  permissions: PermissionManager,
                                  batteryService: any BatteryService) {
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
            let model = PluginDiagnosticsModel(manager: manager, lifecycle: lifecycle, diagnostics: diagnostics)
            pluginDiagnosticsModel = model
            let extensionsModel = PluginExtensionsModel(manager: manager, lifecycle: lifecycle,
                permissions: permissions, diagnostics: diagnostics, diagnosticsModel: model)
            pluginExtensionsModel = extensionsModel
            lifecycle.setAutomaticDisableHandler { [weak manager, weak lifecycle, weak model, weak extensionsModel] package, incident in
                guard let manager, let lifecycle else { return }
                Task { @MainActor in
                    do {
                        _ = try await manager.disableIfCurrent(package: package) { [weak lifecycle] in
                            lifecycle?.isCurrentAutomaticDisable(package: package, incident: incident) == true
                        }
                    } catch {
                        if lifecycle.isCurrentAutomaticDisable(package: package, incident: incident) {
                            diagnostics.recordPersistenceFailure(pluginID: package.manifest.id)
                        }
                    }
                    await model?.refresh()
                    await extensionsModel?.refresh()
                }
            }
            pluginStartupTask = Task { [pluginLogger] in
                let report = await manager.discover()
                extensionsModel.setDiscoveryReport(report)
                await extensionsModel.refresh()
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
        menu.addItem(NSMenuItem(title: "插件管理…", action: #selector(showPluginExtensions), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "插件诊断…", action: #selector(showPluginDiagnostics), keyEquivalent: ""))
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

    @objc private func showPluginExtensions() {
        guard let model = pluginExtensionsModel else { return }
        let controller = pluginExtensionsWindowController ?? PluginExtensionsWindowController(
            model: model, onShowDiagnostics: { [weak self] in self?.showPluginDiagnostics() })
        pluginExtensionsWindowController = controller
        controller.show()
    }

    @objc fileprivate func showPluginDiagnostics() {
        guard let model = pluginDiagnosticsModel else { return }
        let controller = pluginDiagnosticsWindowController ?? PluginDiagnosticsWindowController(model: model)
        pluginDiagnosticsWindowController = controller
        controller.show()
        Task { await model.refresh() }
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
