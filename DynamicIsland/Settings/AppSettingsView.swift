import AppKit
import Combine
import SwiftUI

nonisolated enum AppSettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, calendar, plugins, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "通用"
        case .appearance: "外观"
        case .calendar: "日历与提醒"
        case .plugins: "插件"
        case .about: "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .calendar: "calendar.badge.clock"
        case .plugins: "puzzlepiece.extension"
        case .about: "info.circle"
        }
    }
}

nonisolated enum AppPluginSettingsSection: String, CaseIterable, Identifiable {
    case installed, discover, diagnostics, install

    var id: Self { self }

    var title: String {
        switch self {
        case .installed: "已安装"
        case .discover: "发现"
        case .diagnostics: "诊断"
        case .install: "安装"
        }
    }
}

/// Keeps navigation and the app's shared plugin models across window openings.
/// Opening settings does not change plugin permissions or start a catalog request.
@MainActor
final class AppSettingsModel: ObservableObject {
    @Published var selectedTab: AppSettingsTab
    @Published var pluginSection: AppPluginSettingsSection
    @Published var pluginExtensionsModel: PluginExtensionsModel?
    @Published var pluginRegistryModel: PluginRegistryModel?
    @Published var pluginDiagnosticsModel: PluginDiagnosticsModel?
    @Published var pluginInstallerModel: PluginInstallerModel?
    @Published var musicProviders: OptionalMusicProviderRegistry?
    @Published var calendarAgenda: CalendarAgendaModel?
    @Published var homeSettings: IslandHomeSettings?

    init(selectedTab: AppSettingsTab = .general,
         pluginSection: AppPluginSettingsSection = .installed,
         pluginExtensionsModel: PluginExtensionsModel? = nil,
         pluginRegistryModel: PluginRegistryModel? = nil,
         pluginDiagnosticsModel: PluginDiagnosticsModel? = nil,
         pluginInstallerModel: PluginInstallerModel? = nil) {
        self.selectedTab = selectedTab
        self.pluginSection = pluginSection
        self.pluginExtensionsModel = pluginExtensionsModel
        self.pluginRegistryModel = pluginRegistryModel
        self.pluginDiagnosticsModel = pluginDiagnosticsModel
        self.pluginInstallerModel = pluginInstallerModel
    }
}

@MainActor
struct AppSettingsView: View {
    // Preserve the installed-plugin page's 800 × 600 pt canvas beside the
    // 159 pt settings sidebar, with a 40 pt plugin navigation row above it.
    static let minimumContentSize = CGSize(width: 960, height: 640)

    @ObservedObject private var model: AppSettingsModel
    @AppStorage(IslandAppearance.defaultsKey) private var appearance: IslandAppearance = .classic
    private let onImport: @MainActor () -> Void
    private let onDownload: @MainActor (PluginRegistryEntry) -> Void
    private let onCancelInstall: @MainActor () -> Void
    private let onShowIsland: @MainActor () -> Void
    private let onHideIsland: @MainActor () -> Void
    private let onCopyDiagnosticInfo: @MainActor () -> Void

    init(model: AppSettingsModel,
         onImport: @escaping @MainActor () -> Void,
         onDownload: @escaping @MainActor (PluginRegistryEntry) -> Void,
         onCancelInstall: @escaping @MainActor () -> Void,
         onShowIsland: @escaping @MainActor () -> Void,
         onHideIsland: @escaping @MainActor () -> Void,
         onCopyDiagnosticInfo: @escaping @MainActor () -> Void) {
        self.model = model
        self.onImport = onImport
        self.onDownload = onDownload
        self.onCancelInstall = onCancelInstall
        self.onShowIsland = onShowIsland
        self.onHideIsland = onHideIsland
        self.onCopyDiagnosticInfo = onCopyDiagnosticInfo
    }

    var body: some View {
        HStack(spacing: 0) {
            tabNavigation
            Divider()
            selectedPage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .islandPaging(enabled: true) { step in
                    if model.selectedTab == .plugins {
                        stepPluginSection(by: step)
                    } else {
                        stepTab(by: step)
                    }
                }
        }
        .frame(minWidth: Self.minimumContentSize.width,
               minHeight: Self.minimumContentSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("app-settings")
    }

    private var tabNavigation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("设置")
                .font(.headline)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            ForEach(AppSettingsTab.allCases) { tab in
                Button {
                    model.selectedTab = tab
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.systemImage).frame(width: 20)
                        Text(tab.title)
                        Spacer(minLength: 0)
                    }
                    .font(.system(.body, weight: model.selectedTab == tab ? .semibold : .regular))
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.selectedTab == tab ? Color.accentColor : Color.primary)
                .background(model.selectedTab == tab ? Color.accentColor.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(model.selectedTab == tab ? .isSelected : [])
                .accessibilityIdentifier("settings-tab-\(tab.rawValue)")
            }
            Spacer(minLength: 16)
        }
        .padding(.horizontal, 10)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .frame(width: 159)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-tabs")
        .islandPaging(enabled: true) { step in stepTab(by: step) }
    }

    private func stepTab(by offset: Int) {
        let tabs = AppSettingsTab.allCases
        guard let index = tabs.firstIndex(of: model.selectedTab) else { return }
        model.selectedTab = tabs[min(max(index + offset, 0), tabs.count - 1)]
    }

    private func stepPluginSection(by offset: Int) {
        let sections = visiblePluginSections
        guard let index = sections.firstIndex(of: model.pluginSection) else { return }
        model.pluginSection = sections[min(max(index + offset, 0), sections.count - 1)]
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch model.selectedTab {
        case .general: generalPage
        case .appearance: appearancePage
        case .calendar:
            if let calendarAgenda = model.calendarAgenda {
                CalendarSettingsView(model: calendarAgenda)
            } else {
                SettingsDetailPage(title: "日历与提醒", subtitle: "日历功能正在准备。") {
                    ProgressView()
                }
            }
        case .plugins: pluginPage
        case .about: aboutPage
        }
    }

    private var generalPage: some View {
        SettingsDetailPage(title: "通用", subtitle: "控制灵动岛的显示与日常使用。") {
            if let musicProviders = model.musicProviders {
                MusicSourceSettingsView(providers: musicProviders)
            }
            if let homeSettings = model.homeSettings {
                HomeNavigationSettingsView(settings: homeSettings)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Label("灵动岛", systemImage: "rectangle.topthird.inset.filled")
                        .font(.headline)
                    Text("在屏幕顶部查看音乐、计时器和插件活动。")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button("显示灵动岛", action: onShowIsland)
                            .accessibilityIdentifier("settings-show-island")
                        Button("隐藏灵动岛", action: onHideIsland)
                            .accessibilityIdentifier("settings-hide-island")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("设置窗口", systemImage: "macwindow").font(.headline)
                    Text("关闭设置窗口后，Dynamic Island 会继续运行。你可以从菜单栏或岛内的设置按钮再次打开设置。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("settings-general")
    }

    private var appearancePage: some View {
        SettingsDetailPage(title: "外观", subtitle: "选择灵动岛的背景风格，切换后立即生效。") {
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Label("背景风格", systemImage: "paintpalette").font(.headline)
                    Picker("外观", selection: $appearance) {
                        ForEach(IslandAppearance.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings-island-appearance")
                    .islandPagingExcluded()
                    Text(appearance.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    LabeledContent("紧凑状态", value: "活动概览")
                    LabeledContent("展开状态", value: "详细内容与操作")
                    Text("封面流光与封面光晕用于音乐背景；透明毛玻璃适用于所有页面。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("查看灵动岛", action: onShowIsland)
                        .accessibilityIdentifier("settings-preview-island")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("settings-appearance")
    }

    private var pluginPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    ForEach(visiblePluginSections) { section in
                        Button {
                            model.pluginSection = section
                        } label: {
                            Text(section.title)
                                .font(.system(.body, weight: model.pluginSection == section ? .semibold : .regular))
                                .frame(width: 76, height: 28)
                                .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(model.pluginSection == section ? Color.accentColor : Color.primary)
                        .background(model.pluginSection == section ? Color.accentColor.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityAddTraits(model.pluginSection == section ? .isSelected : [])
                        .accessibilityIdentifier("settings-plugin-section-\(section.rawValue)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings-plugin-sections")
                Spacer(minLength: 0)
                Button(action: onImport) {
                    Label("导入插件…", systemImage: "square.and.arrow.down")
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
                .accessibilityIdentifier("settings-import-plugin")
            }
            .padding(.horizontal, 16)
            .frame(height: 39)
            Divider()
            pluginContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("settings-plugins")
    }

    private var visiblePluginSections: [AppPluginSettingsSection] {
        var sections: [AppPluginSettingsSection] = [.installed, .discover, .diagnostics]
        if model.pluginInstallerModel?.hasPendingImport == true || model.pluginSection == .install {
            sections.append(.install)
        }
        return sections
    }

    @ViewBuilder
    private var pluginContent: some View {
        switch model.pluginSection {
        case .installed:
            if let extensions = model.pluginExtensionsModel {
                PluginExtensionsView(model: extensions, onShowDiagnostics: {
                    model.pluginSection = .diagnostics
                }, onImport: onImport, onDiscover: {
                    model.pluginSection = .discover
                })
            } else {
                pluginPreparingPage
            }
        case .discover:
            if let registry = model.pluginRegistryModel {
                PluginRegistryView(model: registry, onDownload: onDownload)
                    .onDisappear { registry.cancelRefresh() }
            } else {
                pluginPreparingPage
            }
        case .diagnostics:
            if let diagnostics = model.pluginDiagnosticsModel {
                PluginDiagnosticsView(model: diagnostics)
            } else {
                pluginPreparingPage
            }
        case .install:
            if let installer = model.pluginInstallerModel {
                PluginInstallerView(model: installer, onCancel: onCancelInstall)
            } else {
                pluginPreparingPage
            }
        }
    }

    private var pluginPreparingPage: some View {
        ContentUnavailableView("插件功能正在准备", systemImage: "puzzlepiece.extension",
                               description: Text("初始化完成后，可在这里管理插件。"))
    }

    private var aboutPage: some View {
        SettingsDetailPage(title: "关于", subtitle: "应用信息与诊断支持。") {
            HStack(alignment: .center, spacing: 20) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(appName).font(.system(size: 26, weight: .semibold))
                    Text("屏幕顶部的活动与快捷操作。")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)
            GroupBox {
                VStack(spacing: 12) {
                    LabeledContent("版本", value: bundleValue("CFBundleShortVersionString"))
                        .accessibilityIdentifier("settings-app-version")
                    Divider()
                    LabeledContent("构建", value: bundleValue("CFBundleVersion"))
                        .accessibilityIdentifier("settings-app-build")
                }
                .padding(12)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("诊断信息", systemImage: "stethoscope").font(.headline)
                    Text("复制当前运行信息，便于排查显示和运行问题。")
                        .foregroundStyle(.secondary)
                    Button("复制诊断信息", action: onCopyDiagnosticInfo)
                        .accessibilityIdentifier("settings-copy-diagnostic-info")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier("settings-about")
    }

    private var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Dynamic Island"
    }

    private func bundleValue(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else { return "未提供" }
        return value
    }
}

@MainActor
private struct MusicSourceSettingsView: View {
    @ObservedObject var providers: OptionalMusicProviderRegistry

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("音乐播放器", systemImage: "music.note").font(.headline)
                VStack(alignment: .leading, spacing: 5) {
                    Text("自动识别音源").font(.body.weight(.medium))
                    Text(sourceStatusText)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-music-source-status")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("自动跟随系统当前活动音源。第三方播放器需安装并启用对应插件，读取歌曲和控制播放需分别授权。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("已启用来源：\(providers.providers.map(\.displayName).joined(separator: "、"))")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sourceStatusText: String {
        switch providers.sourceStatus {
        case .detecting: "正在识别音源…"
        case .idle: "未检测到活动音源"
        case .active(let name): "当前音源：\(name)"
        case .unavailable(let name): "\(name) 尚未就绪，请在插件页启用并授权。"
        case .unsupported: "当前音源暂不支持"
        case .failed: "暂时无法识别音源，稍后自动重试。"
        }
    }
}

@MainActor
private struct SettingsDetailPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.largeTitle.weight(.semibold))
                    Text(subtitle).foregroundStyle(.secondary)
                }
                content
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}
