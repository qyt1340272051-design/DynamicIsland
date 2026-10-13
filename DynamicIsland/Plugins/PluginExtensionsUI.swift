import AppKit
import Foundation
import SwiftUI

/// User-facing permission descriptions are Host constants. Plugins cannot
/// replace the privacy explanation presented by an approval confirmation.
nonisolated enum PluginPermissionPresentation {
    static func title(_ permission: PluginPermission) -> String {
        switch permission {
        case .network: "访问网络"
        case .localStorage: "保存插件数据"
        case .readClipboard: "读取剪贴板"
        case .writeClipboard: "写入剪贴板"
        case .userSelectedFiles: "读取你选择的文件"
        case .publishNotifications: "发送通知"
        case .readCalendar: "读取日历"
        }
    }

    static func explanation(_ permission: PluginPermission) -> String {
        switch permission {
        case .network: "允许访问受限制的 HTTPS 服务，读取在线数据。"
        case .localStorage: "在本机保存此插件的数据和偏好设置，与其他插件分开存放。"
        case .readClipboard: "可读取剪贴板中的文字，其中可能包含密码、验证码或其他敏感内容。请仅向你信任的插件授权。"
        case .writeClipboard: "可用插件生成的文字替换剪贴板内容。此权限不会允许读取剪贴板。"
        case .userSelectedFiles: "通过系统对话框读取你明确选择的文件；每次选择都需要你确认。"
        case .publishNotifications: "允许插件发送系统通知。此版本尚未支持。"
        case .readCalendar: "允许插件读取日历中的事件。此版本尚未支持。"
        }
    }

    static func stateTitle(_ state: PluginPermissionState) -> String {
        switch state {
        case .requested: "待授权"
        case .granted: "已允许"
        case .denied: "已拒绝"
        case .revoked: "已撤销"
        }
    }
}

@MainActor
public struct PluginExtensionsView: View {
    @Bindable private var model: PluginExtensionsModel
    private let onShowDiagnostics: (() -> Void)?
    @State private var confirmation: Confirmation?

    public init(model: PluginExtensionsModel, onShowDiagnostics: (() -> Void)? = nil) {
        self.model = model
        self.onShowDiagnostics = onShowDiagnostics
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 800, minHeight: 600)
        .task { await model.refresh() }
        .alert(item: $confirmation) { item in
            switch item {
            case .permission(let review, let permission):
                return Alert(
                    title: Text("允许“\(review.name)”\(PluginPermissionPresentation.title(permission))？"),
                    message: Text("插件版本：\(review.version.description)\n\n\(PluginPermissionPresentation.explanation(permission))\n\n仅向此版本的当前代码授权；代码或权限声明变化后需要重新确认。"),
                    primaryButton: .default(Text("允许此权限")) {
                        confirmation = nil
                        Task { await model.setPermission(decision: .granted, review: review, permission: permission) }
                    },
                    secondaryButton: .cancel(Text("取消")) { confirmation = nil })
            case .uninstall(let review):
                return Alert(
                    title: Text("卸载“\(review.name)”？"),
                    message: Text("插件版本：\(review.version.description)\n\n将停止并移除此插件，撤销它的授权。已保存的插件数据会保留。"),
                    primaryButton: .destructive(Text("卸载插件")) {
                        confirmation = nil
                        Task { await model.uninstall(review) }
                    },
                    secondaryButton: .cancel(Text("取消")) { confirmation = nil })
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Label("已安装", systemImage: "puzzlepiece.extension").font(.headline)
                Spacer(minLength: 4)
                Text("\(model.plugins.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            Divider()
            if model.plugins.isEmpty {
                VStack(spacing: 10) {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Image(systemName: "puzzlepiece.extension").font(.title2).foregroundStyle(.secondary)
                    Text(model.isBusy ? "正在读取插件…" : "暂无已安装插件")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("plugin-extensions-empty")
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.plugins) { plugin in
                            Button { model.selectedID = plugin.id } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(plugin.manifest.name).font(.body.weight(.medium)).lineLimit(2)
                                    HStack(spacing: 6) {
                                        Text("v\(plugin.manifest.version.description)")
                                        Spacer(minLength: 0)
                                        Text(status(for: plugin)).foregroundStyle(statusColor(for: plugin))
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(model.selectedID == plugin.id ? Color.accentColor.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .accessibilityIdentifier("plugin-extensions-plugin-\(plugin.id)")
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.selectedPlugin?.manifest.name ?? "插件管理").font(.title2.weight(.semibold))
                        .lineLimit(2).accessibilityIdentifier("plugin-extensions-title")
                    if let plugin = model.selectedPlugin {
                        Text("v\(plugin.manifest.version.description) · \(status(for: plugin))")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("管理已安装插件及其权限").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if model.isBusy { ProgressView().controlSize(.small).padding(.top, 5) }
                Button { Task { await model.refresh() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("plugin-extensions-refresh")
            }
            .padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = model.error {
                        message(error, symbol: "exclamationmark.circle", color: .red)
                            .accessibilityIdentifier("plugin-extensions-error")
                    }
                    if let error = model.persistenceError {
                        message(error, symbol: "exclamationmark.triangle", color: .orange)
                            .accessibilityIdentifier("plugin-extensions-persistence-error")
                    }
                    if !model.discoveryFailures.isEmpty { discoveryIssues }
                    if let plugin = model.selectedPlugin {
                        pluginDetail(plugin)
                    } else if !model.isBusy {
                        ContentUnavailableView("选择一个插件", systemImage: "puzzlepiece.extension",
                            description: Text("在左侧选择插件，查看详细信息、管理权限或卸载。"))
                            .frame(maxWidth: .infinity, minHeight: 260)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("plugin-extensions-detail")
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func pluginDetail(_ plugin: PluginRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("开发者：\(plugin.manifest.developer ?? "未提供")（插件自行声明，未验证）")
                    .font(.callout).textSelection(.enabled)
                    .accessibilityIdentifier("plugin-extensions-developer")
                HStack(spacing: 8) {
                    Label("原生 JavaScriptCore", systemImage: "checkmark.seal")
                    Text("最低主程序版本 \(plugin.manifest.minimumHostVersion.description)")
                }
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("plugin-extensions-compatibility")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 10) {
                Button(plugin.isEnabled ? "停用插件" : "启用插件") {
                    Task { await model.setEnabled(id: plugin.id, isEnabled: !plugin.isEnabled) }
                }
                .disabled(model.isBusy || (!plugin.isEnabled && model.snapshots[plugin.id]?.quarantine != nil))
                .accessibilityIdentifier("plugin-extensions-enable")
                Button("查看诊断") {
                    Task {
                        await model.showLog(id: plugin.id)
                        onShowDiagnostics?()
                    }
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("plugin-extensions-diagnostics")
                Spacer(minLength: 0)
                Button("卸载…", role: .destructive) {
                    guard let review = model.managementReview(id: plugin.id) else { return }
                    confirmation = .uninstall(review)
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("plugin-extensions-uninstall")
            }

            if model.snapshots[plugin.id]?.quarantine != nil {
                message("插件因重复严重失败已自动隔离。请打开诊断，检查记录后重启插件。",
                        symbol: "exclamationmark.shield", color: .orange)
                    .accessibilityIdentifier("plugin-extensions-quarantine")
            } else if let failure = model.snapshots[plugin.id]?.lastFailure {
                message(failure == .startFailed ? "插件启动失败，当前执行已停止。可在诊断中查看记录并重启。" : "插件停止时发生异常，请查看诊断记录。",
                        symbol: "exclamationmark.triangle", color: .orange)
                    .accessibilityIdentifier("plugin-extensions-lifecycle-error")
            } else if model.snapshots[plugin.id]?.state == .suspended {
                message("插件已暂停，运行环境恢复后会继续运行。", symbol: "pause.circle", color: .secondary)
                    .accessibilityIdentifier("plugin-extensions-suspended")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("权限").font(.headline)
                Text("启用插件不会自动授权。授权仅适用于当前代码，并保存在本机；代码或权限声明变化后需重新确认。撤销立即生效。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if plugin.manifest.permissions.isEmpty {
                Text("此插件未请求额外权限。").font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("plugin-extensions-no-permissions")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(plugin.manifest.permissions.sorted { $0.rawValue < $1.rawValue }, id: \.self) { permission in
                        permissionRow(permission, plugin: plugin)
                        if permission != plugin.manifest.permissions.sorted(by: { $0.rawValue < $1.rawValue }).last {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func permissionRow(_ permission: PluginPermission, plugin: PluginRecord) -> some View {
        let state = model.permissionSnapshots[plugin.id]?.states[permission] ?? .requested
        let supported = PluginExtensionsModel.supports(permission)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(PluginPermissionPresentation.title(permission)).font(.callout.weight(.medium))
                Text(PluginPermissionPresentation.stateTitle(state)).font(.caption)
                    .foregroundStyle(state == .granted ? Color.green : Color.secondary)
                Spacer(minLength: 8)
                if !supported {
                    if let review = model.permissionReview(id: plugin.id) {
                        if state == .granted {
                            Button("撤销") {
                                Task { await model.setPermission(decision: .revoked, review: review, permission: permission) }
                            }
                            .accessibilityIdentifier("plugin-extensions-revoke-\(permission.rawValue)")
                        } else if state == .requested {
                            Button("拒绝") {
                                Task { await model.setPermission(decision: .denied, review: review, permission: permission) }
                            }
                            .accessibilityIdentifier("plugin-extensions-deny-\(permission.rawValue)")
                        }
                    }
                    Button("尚未支持") {}.disabled(true)
                } else if let review = model.permissionReview(id: plugin.id) {
                    if state == .granted {
                        Button("撤销") {
                            Task { await model.setPermission(decision: .revoked, review: review, permission: permission) }
                        }
                        .accessibilityIdentifier("plugin-extensions-revoke-\(permission.rawValue)")
                    } else {
                        if state == .requested {
                            Button("拒绝") {
                                Task { await model.setPermission(decision: .denied, review: review, permission: permission) }
                            }
                            .accessibilityIdentifier("plugin-extensions-deny-\(permission.rawValue)")
                        }
                        Button(state == .denied ? "重新授权…" : "授权…") {
                            confirmation = .permission(review, permission)
                        }
                        .accessibilityIdentifier("plugin-extensions-approve-\(permission.rawValue)")
                    }
                }
            }
            Text(PluginPermissionPresentation.explanation(permission))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
        .disabled(model.isBusy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plugin-extensions-permission-\(permission.rawValue)")
    }

    private var discoveryIssues: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(model.discoveryFailures.count) 项插件未能载入", systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.medium))
            Text("请检查插件是否兼容或重新安装。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.discoveryFailures) { issue in
                Text(issue.code).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("plugin-extensions-discovery-errors")
    }

    private func message(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol).font(.callout).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func status(for plugin: PluginRecord) -> String {
        guard let snapshot = model.snapshots[plugin.id] else { return plugin.isEnabled ? "已启用" : "已停用" }
        if snapshot.quarantine != nil { return "已隔离" }
        if snapshot.lastFailure == .startFailed { return "启动失败" }
        return switch snapshot.state {
        case .installed: "已安装"
        case .loaded: "已加载"
        case .running: "运行中"
        case .suspended: "已暂停"
        case .stopped: "已停止"
        case .disabled: "已停用"
        }
    }

    private func statusColor(for plugin: PluginRecord) -> Color {
        if model.snapshots[plugin.id]?.lastFailure == .startFailed { return .red }
        if model.snapshots[plugin.id]?.quarantine != nil { return .orange }
        return model.snapshots[plugin.id]?.state == .running ? .green : .secondary
    }

    private enum Confirmation: Identifiable {
        case permission(PluginPermissionReview, PluginPermission)
        case uninstall(PluginManagementReview)

        var id: String {
            switch self {
            case .permission(let review, let permission): "permission-\(review.scope.uuidString)-\(permission.rawValue)"
            case .uninstall(let review): "uninstall-\(review.id)"
            }
        }
    }
}

@MainActor
public final class PluginExtensionsWindowController: NSWindowController {
    private let model: PluginExtensionsModel

    public init(model: PluginExtensionsModel, onShowDiagnostics: (() -> Void)? = nil) {
        self.model = model
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 860, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "插件管理"
        window.contentMinSize = CGSize(width: 800, height: 600)
        window.minSize = window.frameRect(forContentRect: CGRect(x: 0, y: 0, width: 800, height: 600)).size
        window.isReleasedWhenClosed = false
        let hostingView = NSHostingView(rootView: PluginExtensionsView(model: model, onShowDiagnostics: onShowDiagnostics))
        hostingView.frame = CGRect(x: 0, y: 0, width: 860, height: 680)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        super.init(window: window)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    public func show() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Task { await model.refresh() }
    }
}
