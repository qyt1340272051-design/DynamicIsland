import AppKit
import Foundation
import Observation
import SwiftUI

nonisolated enum PluginRegistryMessages {
    static func message(_ error: PluginRegistryError) -> String {
        switch error {
        case .invalidCatalog, .unsupportedSchema, .duplicatePlugin: "插件目录格式无效或当前版本不支持，请稍后重试。"
        case .invalidURL, .redirectRejected: "下载地址不符合允许的来源范围，已停止请求。"
        case .tooLarge: "插件目录或下载文件超过允许的大小，已停止请求。"
        case .transportFailed: "无法连接插件目录或下载服务，请检查网络后重试。"
        case .httpStatus: "插件目录或下载文件暂不可用，可能尚未发布。可稍后重试或使用本地导入。"
        case .cancelled: "请求已取消。"
        case .busy: "已有目录请求正在处理，请稍后重试。"
        }
    }
}

@MainActor
@Observable
public final class PluginRegistryModel {
    public enum Phase { case idle, loading, loaded, cancelling }
    public nonisolated static let officialSource = URL(string: "https://raw.githubusercontent.com/qyt1340272051-design/DynamicIsland/main/Registry/registry.json")!
    public let sourceURL: URL
    public let hostVersion: SemanticVersion
    public let installerModel: PluginInstallerModel
    public private(set) var phase: Phase = .idle
    public private(set) var entries: [PluginRegistryEntry] = []
    public private(set) var errorMessage: String?
    public private(set) var errorCode: String?
    public private(set) var isTerminating = false
    public var isRefreshing: Bool { phase == .loading || phase == .cancelling }
    public var canRefresh: Bool { !isRefreshing && !isTerminating && !installerModel.hasPendingImport && !installerModel.isTerminating }

    private let loadCatalog: @Sendable (URL) async throws -> PluginRegistryCatalog
    private var refreshTask: Task<PluginRegistryCatalog, Error>?

    public init(sourceURL: URL = PluginRegistryModel.officialSource, hostVersion: SemanticVersion,
                installerModel: PluginInstallerModel,
                loadCatalog: @escaping @Sendable (URL) async throws -> PluginRegistryCatalog) {
        self.sourceURL = sourceURL
        self.hostVersion = hostVersion
        self.installerModel = installerModel
        self.loadCatalog = loadCatalog
    }

    public func isCompatible(_ entry: PluginRegistryEntry) -> Bool { hostVersion.isAtLeast(entry.minHostVersion) }

    public func canDownload(_ entry: PluginRegistryEntry) -> Bool {
        phase == .loaded && !isTerminating && !installerModel.isTerminating && !installerModel.hasPendingImport
            && entries.contains(entry) && isCompatible(entry)
    }

    public func refresh() async {
        guard canRefresh else { return }
        phase = .loading
        entries = []
        errorMessage = nil; errorCode = nil
        let source = sourceURL, loader = loadCatalog
        let task = Task { try await loader(source) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let catalog = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard !task.isCancelled, !Task.isCancelled, !isTerminating else { phase = .idle; return }
            entries = catalog.entries
            phase = .loaded
        } catch {
            phase = .idle
            guard !task.isCancelled, !Task.isCancelled, !isTerminating else { return }
            let failure = error as? PluginRegistryError ?? .transportFailed
            errorCode = failure.rawValue
            errorMessage = PluginRegistryMessages.message(failure)
        }
    }

    public func cancelRefresh() {
        guard let refreshTask else { return }
        phase = .cancelling
        refreshTask.cancel()
    }

    @discardableResult
    public func download(_ entry: PluginRegistryEntry) async -> Bool {
        guard canDownload(entry) else { return false }
        return await installerModel.importRegistryEntry(entry)
    }

    public func shutdown() async {
        isTerminating = true
        cancelRefresh()
        _ = await refreshTask?.result
    }

    /// Quit can be cancelled by Installer cleanup failure. Reopening discovery
    /// is safe only after the Host explicitly abandons that quit attempt.
    public func resumeAfterCancelledTermination() { isTerminating = false }
}

@MainActor
public struct PluginRegistryView: View {
    @Bindable private var model: PluginRegistryModel
    private let onDownload: @MainActor (PluginRegistryEntry) -> Void

    public init(model: PluginRegistryModel, onDownload: @escaping @MainActor (PluginRegistryEntry) -> Void) {
        self.model = model
        self.onDownload = onDownload
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension").font(.title)
                VStack(alignment: .leading, spacing: 4) {
                    Text("发现插件").font(.title2.weight(.semibold))
                    Text("从项目目录查看可用插件").foregroundStyle(.secondary)
                }
                Spacer()
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                    Button("取消刷新") { model.cancelRefresh() }
                        .disabled(model.phase == .cancelling)
                        .accessibilityIdentifier("plugin-registry-cancel-refresh")
                } else {
                    Button("刷新目录") { Task { await model.refresh() } }
                        .disabled(!model.canRefresh)
                        .accessibilityIdentifier("plugin-registry-refresh")
                }
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        if let code = model.errorCode { Text("错误代码：\(code)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                    } else if model.phase == .loading {
                        Text("正在读取插件目录…").foregroundStyle(.secondary)
                    } else if model.phase == .cancelling {
                        Text("正在取消刷新…").foregroundStyle(.secondary)
                    } else if model.phase == .idle {
                        Text("点击“刷新目录”获取可用插件。打开此窗口不会自动联网。")
                    } else if model.entries.isEmpty {
                        Text("目录中暂时没有可用插件。").font(.headline)
                        Text("已获取目录；新的插件发布后会在此列出，也可以在插件管理中导入本地 .dip 文件。")
                            .foregroundStyle(.secondary)
                    }
                    if model.installerModel.hasPendingImport {
                        Label("请先完成或取消当前安装，再下载其他插件。", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                                    Text("版本 \(entry.version.description) · 最低主程序 \(entry.minHostVersion.description)")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 12)
                                Button("下载并查看") { onDownload(entry) }
                                    .disabled(!model.canDownload(entry))
                                    .accessibilityIdentifier("plugin-registry-download-\(entry.id)")
                            }
                            Text(entry.id).font(.caption.monospaced()).textSelection(.enabled)
                            Text("来源：\(entry.source.absoluteString)").font(.caption)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            if !model.isCompatible(entry) {
                                Text("需要更新 Dynamic Island 后才能安装。").font(.callout).foregroundStyle(.orange)
                            }
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Text("目录提供来源信息，不代表身份认证。下载后仍需检查插件信息与权限；安装不会自动启用或授权。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(16)
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
public final class PluginRegistryWindowController: NSWindowController, NSWindowDelegate {
    private let model: PluginRegistryModel

    public convenience init(model: PluginRegistryModel, onDownload: @escaping @MainActor (PluginRegistryEntry) -> Void) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        self.init(model: model, eventWindow: window, onDownload: onDownload)
    }

    init(model: PluginRegistryModel, eventWindow window: NSWindow,
         onDownload: @escaping @MainActor (PluginRegistryEntry) -> Void) {
        self.model = model
        window.title = "发现插件"
        window.isReleasedWhenClosed = false
        window.contentMinSize = CGSize(width: 720, height: 480)
        window.minSize = window.frameRect(forContentRect: CGRect(x: 0, y: 0, width: 720, height: 480)).size
        window.contentView = NSHostingView(rootView: PluginRegistryView(model: model, onDownload: onDownload))
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    public func show() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        if !(window is NSPanel) { NSApp.activate() }
        window.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) { model.cancelRefresh() }
}
