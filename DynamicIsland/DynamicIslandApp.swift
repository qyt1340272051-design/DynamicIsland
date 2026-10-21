import AppKit
import Combine
import OSLog
import SwiftUI
import UniformTypeIdentifiers

@main
struct DynamicIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            PluginSettingsContent(appDelegate: appDelegate)
        }
    }
}

/// Observe startup from a View. The Settings scene builder itself does not
/// subscribe to the delegate's later publication of the initialized model.
@MainActor
private struct PluginSettingsContent: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        if let model = appDelegate.pluginExtensionsModel {
            PluginExtensionsView(model: model, onShowDiagnostics: { appDelegate.showPluginDiagnostics() },
                                 onImport: { appDelegate.importPlugin() }, onDiscover: { appDelegate.showPluginRegistry() })
        } else {
            ContentUnavailableView("插件管理暂不可用", systemImage: "puzzlepiece.extension",
                                   description: Text("请等待插件初始化完成。"))
                .frame(width: 800, height: 600)
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
    private var pluginInstallerModel: PluginInstallerModel?
    private var pluginInstallerWindowController: PluginInstallerWindowController?
    private var pluginRegistryModel: PluginRegistryModel?
    private var pluginRegistryWindowController: PluginRegistryWindowController?
    private lazy var pluginImportCoordinator = PluginImportCoordinator { [weak self] in
        self?.showPluginInstaller()
    }
    private var pluginTerminationTask: Task<Void, Never>?
    private var pluginTerminationApproved = false
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

    func application(_ application: NSApplication, open urls: [URL]) {
        pluginImportCoordinator.enqueue(urls)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if pluginTerminationApproved { return .terminateNow }
        guard pluginInstallerModel != nil || pluginImportCoordinator.pendingCount > 0 else { return .terminateNow }
        guard pluginTerminationTask == nil else { return .terminateCancel }
        pluginTerminationTask = Task { @MainActor [weak self] in
            await self?.pluginRegistryModel?.shutdown()
            let cleaned = await self?.pluginImportCoordinator.shutdown() ?? true
            if cleaned {
                self?.pluginTerminationApproved = true
                sender.terminate(nil)
            } else {
                self?.pluginTerminationTask = nil
                self?.pluginRegistryModel?.resumeAfterCancelledTermination()
                NotificationCenter.default.post(name: .islandQuitCancelled, object: nil)
                self?.showPluginInstaller()
            }
        }
        // A Swift MainActor job can call terminate (the animated quit button
        // does). terminateLater nests AppKit's modal loop inside that job and
        // prevents the cleanup Task from acquiring the same executor. Cancel
        // this attempt, clean up after the job returns, then terminateNow.
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusFeedbackTask?.cancel()
        pluginStartupTask?.cancel()
        pluginEnvironment?.stop()
        pluginDiagnosticsWindowController?.close()
        pluginExtensionsWindowController?.close()
        pluginInstallerWindowController?.finishClose()
        pluginRegistryWindowController?.close()
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
            let model = PluginDiagnosticsModel(manager: manager, lifecycle: lifecycle, diagnostics: diagnostics,
                hostSchedulingProvider: { [weak self] in
                    guard let runtime = self?.activityRuntime else { return nil }
                    return PluginHostSchedulingSnapshot(
                        policy: runtime.pluginScheduler.snapshot.policy,
                        appActive: NSApp.isActive,
                        appFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier
                            == ProcessInfo.processInfo.processIdentifier,
                        lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
                    )
                })
            pluginDiagnosticsModel = model
            let extensionsModel = PluginExtensionsModel(manager: manager, lifecycle: lifecycle,
                permissions: permissions, diagnostics: diagnostics, diagnosticsModel: model)
            pluginExtensionsModel = extensionsModel
            let installer = PluginInstaller(manager: manager, configuration: configuration)
            let registryClient = PluginRegistryClient()
            let installerModel = PluginInstallerModel(installer: installer, registryPrepare: { entry in
                try await registryClient.prepareDownload(entry, installer: installer)
            }, onInstalled: { [weak self, weak extensionsModel] record in
                guard self?.pluginTerminationTask == nil else { return }
                await extensionsModel?.refresh()
                extensionsModel?.selectedID = record.id
                self?.pluginInstallerWindowController?.finishClose()
                self?.showPluginExtensions()
            }, onInstallFailure: { [weak self, weak extensionsModel] review, code in
                guard self?.pluginTerminationTask == nil else { return }
                await extensionsModel?.refresh()
                if code == "cleanupFailed", self?.pluginInstallerModel?.installedID == review.id {
                    let installed = await manager.plugins()
                    if installed.contains(where: { $0.id == review.id && $0.manifest.version == review.version }) {
                        extensionsModel?.selectedID = review.id
                    }
                    self?.showPluginExtensions()
                    self?.showPluginInstaller()
                }
            })
            pluginInstallerModel = installerModel
            let registryModel = PluginRegistryModel(hostVersion: configuration.hostVersion, installerModel: installerModel,
                loadCatalog: { url in try await registryClient.loadCatalog(from: url) })
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
                guard !Task.isCancelled else { return }
                self.pluginImportCoordinator.configure(model: installerModel)
                self.pluginRegistryModel = registryModel
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
        menu.addItem(NSMenuItem(title: "导入插件…", action: #selector(importPlugin), keyEquivalent: ""))
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
            model: model, onShowDiagnostics: { [weak self] in self?.showPluginDiagnostics() },
            onImport: { [weak self] in self?.importPlugin() }, onDiscover: { [weak self] in self?.showPluginRegistry() })
        pluginExtensionsWindowController = controller
        controller.show()
    }

    fileprivate func showPluginRegistry() {
        guard let model = pluginRegistryModel, pluginTerminationTask == nil else { return }
        let controller = pluginRegistryWindowController ?? PluginRegistryWindowController(model: model, onDownload: { [weak self] entry in
            guard let self, self.pluginTerminationTask == nil, model.canDownload(entry) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.pluginTerminationTask == nil, model.canDownload(entry) else { return }
                self.showPluginInstaller()
                _ = await model.download(entry)
            }
        })
        pluginRegistryWindowController = controller
        controller.show()
    }

    @objc fileprivate func importPlugin() {
        guard let model = pluginInstallerModel else {
            let alert = NSAlert()
            alert.messageText = "插件导入暂不可用"
            alert.informativeText = "请等待插件初始化完成后重试。"
            alert.addButton(withTitle: "好")
            NSApp.activate()
            alert.runModal()
            return
        }
        guard !model.hasPendingImport else {
            model.rejectBusy()
            showPluginInstaller()
            return
        }
        let panel = NSOpenPanel()
        panel.title = "导入 Dynamic Island 插件"
        panel.message = "选择一个 .dip 插件包，检查信息与权限后安装。"
        panel.allowedContentTypes = [UTType(exportedAs: "com.rong5.dynamic-island.plugin", conformingTo: .zip)]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.pluginImportCoordinator.enqueue([url])
        }
    }

    private func showPluginInstaller() {
        guard let model = pluginInstallerModel, pluginTerminationTask == nil else { return }
        let controller = pluginInstallerWindowController ?? PluginInstallerWindowController(model: model)
        pluginInstallerWindowController = controller
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
