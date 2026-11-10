import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

@main
enum DynamicIslandApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
private struct AppSettingsScene: Scene {
    let appDelegate: AppDelegate

    var body: some Scene {
        Settings {
            AppSettingsView(model: appDelegate.settingsModel,
                onImport: { appDelegate.importPlugin() },
                onDownload: { appDelegate.downloadPlugin($0) },
                onCancelInstall: { appDelegate.cancelPluginInstall() },
                onShowIsland: { appDelegate.showIsland() },
                onHideIsland: { appDelegate.hideIsland() },
                onCopyDiagnosticInfo: { appDelegate.copyDiagnosticInfo() })
                .background(AppSettingsWindowReader { appDelegate.settingsWindowCoordinator.attach(to: $0) })
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    fileprivate let settingsModel = AppSettingsModel()
    private let toolPlacements = PluginToolPlacementStore.applicationSupport()
    private var settingsScene: NSHostingSceneRepresentation<AppSettingsScene>?
    fileprivate lazy var settingsWindowCoordinator = AppSettingsWindowCoordinator(
        installer: { [weak self] in self?.pluginInstallerModel },
        onShowInstaller: { [weak self] in self?.showPluginInstaller() },
        onClose: { [weak self] in self?.pluginRegistryModel?.cancelRefresh() })
    private var pluginExtensionsModel: PluginExtensionsModel? {
        get { settingsModel.pluginExtensionsModel }
        set { settingsModel.pluginExtensionsModel = newValue }
    }
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
    private var pluginDiagnosticsModel: PluginDiagnosticsModel? {
        get { settingsModel.pluginDiagnosticsModel }
        set { settingsModel.pluginDiagnosticsModel = newValue }
    }
    private var pluginInstallerModel: PluginInstallerModel? {
        get { settingsModel.pluginInstallerModel }
        set { settingsModel.pluginInstallerModel = newValue }
    }
    private var pluginRegistryModel: PluginRegistryModel? {
        get { settingsModel.pluginRegistryModel }
        set { settingsModel.pluginRegistryModel = newValue }
    }
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
        configureApplicationMenu()
        // Register one native Settings scene. Its public opener also works
        // from the island's standalone AppKit hosting controller.
        let settingsScene = NSHostingSceneRepresentation { AppSettingsScene(appDelegate: self) }
        NSApp.addSceneRepresentation(settingsScene)
        self.settingsScene = settingsScene

        let musicProviders = OptionalMusicProviderRegistry(defaults: .standard)
        settingsModel.musicProviders = musicProviders
        let viewModel = IslandViewModel(musicProviders: musicProviders)
        settingsModel.calendarAgenda = viewModel.calendarAgenda
        settingsModel.homeSettings = viewModel.homeSettings
        viewModel.calendarAgenda.start()
        let screenManager = ScreenManager()
        let batteryService = IOKitBatteryService()
        let activityRuntime = IslandActivityRuntime(
            viewModel: viewModel,
            musicProviders: musicProviders,
            batteryService: batteryService,
            toolPlacements: toolPlacements
        )
        let panelController = IslandPanelController(
            viewModel: viewModel,
            screenManager: screenManager,
            activityRuntime: activityRuntime,
            onOpenSettings: { [weak self] in
                if viewModel.expandedSurface == .music, viewModel.homeLayer != .music {
                    self?.settingsModel.selectedTab = .calendar
                }
                self?.showSettings()
            }
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
        viewModel?.calendarAgenda.stop()
        statusFeedbackTask?.cancel()
        pluginStartupTask?.cancel()
        pluginEnvironment?.stop()
        pluginRegistryModel?.cancelRefresh()
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
            // Optional music providers require the 0.6.1 Host contract.
            let configuration = try PluginManagerConfiguration.applicationSupport(
                hostVersion: SemanticVersion("0.6.1")
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
                permissions: permissions, diagnostics: diagnostics, diagnosticsModel: model,
                toolPlacements: toolPlacements)
            pluginExtensionsModel = extensionsModel
            let installer = PluginInstaller(manager: manager, configuration: configuration)
            let registryClient = PluginRegistryClient()
            let installerModel = PluginInstallerModel(installer: installer, registryPrepare: { entry in
                try await registryClient.prepareDownload(entry, installer: installer)
            }, onInstalled: { [weak self, weak extensionsModel] record in
                guard self?.pluginTerminationTask == nil else { return }
                await extensionsModel?.refresh()
                extensionsModel?.selectedID = record.id
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

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Dynamic Island")
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        applicationMenu.addItem(settingsItem)
        applicationMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "服务")
        servicesItem.submenu = servicesMenu
        applicationMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(NSMenuItem(title: "隐藏 Dynamic Island", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        applicationMenu.addItem(hideOthers)
        applicationMenu.addItem(NSMenuItem(title: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        applicationMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Dynamic Island", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        applicationMenu.addItem(quitItem)
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [
            ("撤销", Selector(("undo:")), "z"),
            ("重做", Selector(("redo:")), "Z"),
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("拷贝", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a")
        ] {
            editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = mainMenu
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.tophalf.filled", accessibilityDescription: "Dynamic Island")
        item.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示 Dynamic Island", action: #selector(showIsland), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "隐藏 Dynamic Island", action: #selector(hideIsland), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "插件管理…", action: #selector(showPluginExtensions), keyEquivalent: ""))
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

    @objc fileprivate func showSettings() {
        guard pluginTerminationTask == nil else { return }
        NSApp.activate()
        settingsScene?.environment.openSettings()
    }

    @objc private func showPluginExtensions() {
        settingsModel.selectedTab = .plugins
        settingsModel.pluginSection = .installed
        showSettings()
    }

    fileprivate func showPluginRegistry() {
        guard pluginRegistryModel != nil, pluginTerminationTask == nil else { return }
        settingsModel.selectedTab = .plugins
        settingsModel.pluginSection = .discover
        showSettings()
    }

    fileprivate func downloadPlugin(_ entry: PluginRegistryEntry) {
        guard let model = pluginRegistryModel, pluginTerminationTask == nil, model.canDownload(entry) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.pluginTerminationTask == nil, model.canDownload(entry) else { return }
            self.showPluginInstaller()
            _ = await model.download(entry)
        }
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
        settingsModel.selectedTab = .plugins
        settingsModel.pluginSection = .installed
        showSettings()
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
        guard pluginInstallerModel != nil, pluginTerminationTask == nil else { return }
        settingsModel.selectedTab = .plugins
        settingsModel.pluginSection = .install
        showSettings()
    }

    fileprivate func cancelPluginInstall() {
        guard let model = pluginInstallerModel, !model.isBusy || model.canCancelDownload else { return }
        Task { @MainActor [weak self] in
            guard await model.cancel() else { return }
            self?.showPluginExtensions()
        }
    }

    @objc fileprivate func showPluginDiagnostics() {
        guard let model = pluginDiagnosticsModel else { return }
        settingsModel.selectedTab = .plugins
        settingsModel.pluginSection = .diagnostics
        showSettings()
        Task { await model.refresh() }
    }

    @objc fileprivate func showIsland() {
        panelController?.show()
    }

    @objc fileprivate func hideIsland() {
        panelController?.hide()
    }

    @objc fileprivate func copyDiagnosticInfo() {
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
