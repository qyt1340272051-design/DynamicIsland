import AppKit
import Foundation
import Observation
import SwiftUI

/// Host-owned scheduling state read alongside a diagnostics refresh. The
/// value contains no other application's identity or user/plugin content.
public nonisolated struct PluginHostSchedulingSnapshot: Equatable, Sendable {
    public let policy: PluginSchedulerPolicy
    public let appActive: Bool
    public let appFrontmost: Bool
    public let lowPowerMode: Bool

    public init(policy: PluginSchedulerPolicy, appActive: Bool,
                appFrontmost: Bool, lowPowerMode: Bool) {
        self.policy = policy
        self.appActive = appActive
        self.appFrontmost = appFrontmost
        self.lowPowerMode = lowPowerMode
    }
}

@MainActor
@Observable
public final class PluginDiagnosticsModel {
    public nonisolated static let restartFailedMessage = "插件重启失败。请查看诊断记录后再试。"

    public private(set) var plugins: [PluginRecord] = []
    public private(set) var snapshots: [String: PluginLifecycleSnapshot] = [:]
    public private(set) var records: [PluginDiagnosticEntry] = []
    public private(set) var hostSchedulingSnapshot: PluginHostSchedulingSnapshot?
    public var selectedID: String?
    public private(set) var isBusy = false
    public private(set) var error: String?

    @ObservationIgnored private let manager: PluginManager
    @ObservationIgnored private let lifecycle: PluginLifecycleBridge
    @ObservationIgnored private let diagnostics: PluginDiagnosticsStore
    @ObservationIgnored private let hostSchedulingProvider: (@MainActor @Sendable () -> PluginHostSchedulingSnapshot?)?
    @ObservationIgnored private var lifecycleObservationID: UUID?
    @ObservationIgnored private var diagnosticsObservationID: UUID?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var isRestarting = false
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(manager: PluginManager, lifecycle: PluginLifecycleBridge,
                diagnostics: PluginDiagnosticsStore,
                hostSchedulingProvider: (@MainActor @Sendable () -> PluginHostSchedulingSnapshot?)? = nil) {
        self.manager = manager
        self.lifecycle = lifecycle
        self.diagnostics = diagnostics
        self.hostSchedulingProvider = hostSchedulingProvider
        lifecycleObservationID = lifecycle.observeChanges { [weak self] in
            self?.requestSnapshotRefresh()
        }
        diagnosticsObservationID = diagnostics.observeChanges { [weak self] in
            self?.requestSnapshotRefresh()
        }
    }

    deinit {
        refreshTask?.cancel()
        if let lifecycleObservationID {
            let lifecycle = lifecycle
            Task { @MainActor in lifecycle.removeChangeObserver(lifecycleObservationID) }
        }
        if let diagnosticsObservationID {
            let diagnostics = diagnostics
            Task { @MainActor in diagnostics.removeChangeObserver(diagnosticsObservationID) }
        }
    }

    public var selectedPlugin: PluginRecord? { plugins.first { $0.id == selectedID } }
    public var selectedSnapshot: PluginLifecycleSnapshot? { selectedID.flatMap { snapshots[$0] } }
    public var selectedRecords: [PluginDiagnosticEntry] {
        guard let selectedID else { return [] }
        return records.filter { $0.pluginID == selectedID }.reversed()
    }

    /// Read only when the panel opens, the user requests refresh, or a Host
    /// lifecycle/diagnostic signal arrives. There is no polling task or timer.
    public func refresh() async {
        await waitUntilIdle()
        await performRefresh(clearError: true)
    }

    private func performRefresh(clearError: Bool) async {
        guard !isBusy else { needsRefresh = true; return }
        isBusy = true
        needsRefresh = false
        defer { finishBusyOperation() }
        if clearError { error = nil }
        await readSnapshot()
    }

    /// Revalidate current disk code before enabling it. Clearing an exact Host
    /// incident preserves the same package's rolling failure history. Failure
    /// ends this user request; there is no automatic retry.
    public func restart(id: String) async {
        guard !isRestarting else { return }
        isRestarting = true
        defer { isRestarting = false }
        await waitUntilIdle()
        isBusy = true
        needsRefresh = false
        defer { finishBusyOperation() }
        error = nil
        if lifecycle.snapshot(id: id)?.quarantine == nil {
            diagnostics.record(pluginID: id, level: .info, category: .restart, code: .restartRequested)
        }
        do {
            _ = try await manager.disable(id: id)
            _ = try await manager.reload(id: id)
            if let incident = lifecycle.snapshot(id: id)?.quarantine {
                guard lifecycle.clearQuarantineForHostRestart(id: id, incident: incident) else {
                    throw RestartFailure.failed
                }
            }
            _ = try await manager.enable(id: id)
            if let snapshot = lifecycle.snapshot(id: id),
               snapshot.quarantine != nil || snapshot.lastFailure == .startFailed {
                throw RestartFailure.failed
            }
        } catch {
            // Manager validation errors can contain paths and plugin metadata.
            // Retain only a Host constant for the user-facing failure state.
            if let managerError = error as? PluginManagerError, managerError == .stateWriteFailed {
                diagnostics.recordPersistenceFailure(pluginID: id)
            }
            self.error = Self.restartFailedMessage
        }
        await readSnapshot()
    }

    private func requestSnapshotRefresh() {
        needsRefresh = true
        guard !isBusy, refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            await self.performRefresh(clearError: false)
        }
    }

    private func finishBusyOperation() {
        isBusy = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
        // Waiting user operations take priority over passive snapshot reads.
        if waiters.isEmpty, needsRefresh { requestSnapshotRefresh() }
    }

    private func waitUntilIdle() async {
        while isBusy {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    private func readSnapshot() async {
        plugins = await manager.plugins()
        var current: [String: PluginLifecycleSnapshot] = [:]
        for plugin in plugins { current[plugin.id] = lifecycle.snapshot(id: plugin.id) }
        snapshots = current
        records = diagnostics.allRecords()
        hostSchedulingSnapshot = hostSchedulingProvider?()
        if !plugins.contains(where: { $0.id == selectedID }) { selectedID = plugins.first?.id }
        // These snapshots are read together on MainActor after Manager returns.
        // A signal received during that await is already included in this read.
        needsRefresh = false
    }

    private enum RestartFailure: Error { case failed }
}

@MainActor
public struct PluginDiagnosticsView: View {
    @Bindable private var model: PluginDiagnosticsModel

    public init(model: PluginDiagnosticsModel) { self.model = model }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 720, minHeight: 480)
        .task { await model.refresh() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("插件").font(.headline)
                Spacer()
                Text("\(model.plugins.count)").foregroundStyle(.secondary)
            }
            .padding(14)
            Divider()
            if model.plugins.isEmpty {
                VStack(spacing: 10) {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Image(systemName: "puzzlepiece.extension").font(.title2).foregroundStyle(.secondary)
                    Text(model.isBusy ? "正在读取插件…" : "暂无已安装插件")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("plugin-diagnostics-empty")
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
                                        Text(status(for: plugin))
                                            .foregroundStyle(statusColor(for: plugin))
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
                            .accessibilityIdentifier("plugin-diagnostics-plugin-\(plugin.id)")
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
                    Text(model.selectedPlugin?.manifest.name ?? "插件诊断")
                        .font(.title2.weight(.semibold))
                    if let plugin = model.selectedPlugin {
                        Text("v\(plugin.manifest.version.description) · \(status(for: plugin))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if model.isBusy { ProgressView().controlSize(.small).padding(.top, 5) }
                Button {
                    Task { await model.refresh() }
                } label: { Label("刷新", systemImage: "arrow.clockwise") }
                .disabled(model.isBusy)
                .accessibilityIdentifier("plugin-diagnostics-refresh")
                Button("重启插件") {
                    guard let id = model.selectedID else { return }
                    Task { await model.restart(id: id) }
                }
                .disabled(model.isBusy || model.selectedPlugin == nil)
                .accessibilityIdentifier("plugin-diagnostics-restart")
            }
            .padding(18)

            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red)
                    .padding(.horizontal, 18).padding(.bottom, 12)
                    .accessibilityIdentifier("plugin-diagnostics-error")
            }
            if model.selectedSnapshot?.quarantine != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Label("插件已因重复严重失败自动停用", systemImage: "exclamationmark.shield")
                        .font(.callout.weight(.medium))
                    Text("重启会重新加载代码，同一代码在一分钟内的失败计数会保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 18).padding(.bottom, 12)
                .accessibilityIdentifier("plugin-diagnostics-quarantine")
            } else if let failure = model.selectedSnapshot?.lastFailure {
                Label(failure == .startFailed ? "插件启动失败，当前执行已停止。" : "插件清理发生异常，请查看诊断记录。",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .padding(.horizontal, 18).padding(.bottom, 12)
                    .accessibilityIdentifier("plugin-diagnostics-lifecycle-failure")
            }
            if let snapshot = model.hostSchedulingSnapshot {
                hostSchedulingDetail(snapshot)
                    .padding(.horizontal, 18).padding(.bottom, 12)
            }
            Text("仅保留固定的诊断类别和错误代码；插件原始日志与异常内容不会保存。记录仅在本次运行中保留。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18).padding(.bottom, 14)
            Divider()
            if model.selectedPlugin == nil {
                ContentUnavailableView("选择一个插件", systemImage: "puzzlepiece.extension",
                                       description: Text("在左侧选择插件，查看状态和诊断记录。"))
            } else if model.selectedRecords.isEmpty {
                ContentUnavailableView("暂无诊断记录", systemImage: "list.bullet.rectangle",
                                       description: Text("插件运行产生的诊断记录会显示在这里。"))
                    .accessibilityIdentifier("plugin-diagnostics-no-records")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.selectedRecords, id: \.sequence) { entry in
                            logRow(entry)
                            Divider().padding(.horizontal, 18)
                        }
                    }
                }
                .accessibilityIdentifier("plugin-diagnostics-records")
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func hostSchedulingDetail(_ snapshot: PluginHostSchedulingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("主程序调度策略：\(snapshot.policy.rawValue)")
                .font(.callout.weight(.medium))
            HStack(spacing: 16) {
                Text("App 活跃（NSApp）：\(snapshot.appActive ? "是" : "否")")
                Text("App 在前台：\(snapshot.appFrontmost ? "是" : "否")")
                Text("低功耗模式：\(snapshot.lowPowerMode ? "开" : "关")")
            }
            .font(.caption).foregroundStyle(.secondary)
            Text("这是刷新时的状态快照；点击刷新更新。读取状态不会改变调度策略。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("plugin-diagnostics-host-scheduling")
    }

    private func logRow(_ entry: PluginDiagnosticEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.level.rawValue.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(levelColor(entry.level))
                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(categoryName(entry.category)).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(entry.code).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(entry.message).font(.callout).textSelection(.enabled)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func status(for plugin: PluginRecord) -> String {
        guard let snapshot = model.snapshots[plugin.id] else { return plugin.isEnabled ? "已启用" : "已停用" }
        if snapshot.quarantine != nil { return "已隔离" }
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
        if model.snapshots[plugin.id]?.quarantine != nil { return .orange }
        return model.snapshots[plugin.id]?.state == .running ? .green : .secondary
    }

    private func levelColor(_ level: PluginLogLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }

    private func categoryName(_ category: PluginDiagnosticCategory) -> String {
        switch category {
        case .pluginMessage: "插件日志"
        case .runtimeFailure: "运行异常"
        case .lifecycleFailure: "生命周期"
        case .actionFailure: "交互异常"
        case .actionLimit: "交互限额"
        case .compatibilityFailure: "兼容异常"
        case .watchdogIsolation: "自动隔离"
        case .persistenceFailure: "状态保存"
        case .restart: "插件重启"
        }
    }
}

@MainActor
public final class PluginDiagnosticsWindowController: NSWindowController {
    private let model: PluginDiagnosticsModel

    public init(model: PluginDiagnosticsModel) {
        self.model = model
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "插件诊断"
        window.minSize = CGSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        let hostingView = NSHostingView(rootView: PluginDiagnosticsView(model: model))
        hostingView.frame = CGRect(x: 0, y: 0, width: 720, height: 480)
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
