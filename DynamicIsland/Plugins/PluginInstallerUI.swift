import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The Host reads a selected archive only while its security scope is open.
/// A false start is normal for already accessible files; no matching stop is
/// needed in that case. Tests inject a lease witness without opening a panel.
@MainActor
public protocol PluginArchiveAccessing {
    func start(_ url: URL) -> Bool
    func stop(_ url: URL)
}

@MainActor
public struct NativePluginArchiveAccess: PluginArchiveAccessing {
    public nonisolated init() {}
    public func start(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    public func stop(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

public nonisolated protocol PluginInstallationHandling: Sendable {
    func prepare(archiveURL: URL) async throws -> PluginInstallReview
    func cancel(_ review: PluginInstallReview) async throws
    func commit(_ review: PluginInstallReview) async throws -> PluginRecord
    func hasPendingCleanup() async -> Bool
    func retryCleanup() async throws
}

extension PluginInstaller: PluginInstallationHandling {}

/// A review never represents permission consent. Installation remains disabled;
/// permission approval and enablement are separate actions in Extensions.
@MainActor
@Observable
public final class PluginInstallerModel {
    public enum Phase { case idle, preparing, reviewing, installing, cancelling }
    public private(set) var phase: Phase = .idle
    public private(set) var review: PluginInstallReview?
    public private(set) var errorMessage: String?
    public private(set) var errorCode: String?
    public private(set) var installedID: String?
    public private(set) var isTerminating = false
    public private(set) var requiresCleanup = false
    public var isBusy: Bool { phase == .preparing || phase == .installing || phase == .cancelling }
    public var hasPendingImport: Bool { phase != .idle || review != nil || requiresCleanup }

    private let installer: any PluginInstallationHandling
    private let archiveAccess: any PluginArchiveAccessing
    private let onInstalled: (@MainActor (PluginRecord) async -> Void)?
    private let onInstallFailure: (@MainActor (PluginInstallReview, String) async -> Void)?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(installer: any PluginInstallationHandling,
                archiveAccess: any PluginArchiveAccessing = NativePluginArchiveAccess(),
                onInstalled: (@MainActor (PluginRecord) async -> Void)? = nil,
                onInstallFailure: (@MainActor (PluginInstallReview, String) async -> Void)? = nil) {
        self.installer = installer
        self.archiveAccess = archiveAccess
        self.onInstalled = onInstalled
        self.onInstallFailure = onInstallFailure
    }

    @discardableResult
    public func importArchive(_ url: URL) async -> Bool {
        guard !isTerminating else { return false }
        guard !hasPendingImport else { rejectBusy(); return false }
        guard url.isFileURL, url.pathExtension.lowercased() == "dip" else {
            setError(code: "invalidArguments", message: "请选择有效的 .dip 插件包。"); return false
        }
        phase = .preparing
        review = nil
        installedID = nil
        requiresCleanup = false
        clearError()
        let accessed = archiveAccess.start(url)
        defer { if accessed { archiveAccess.stop(url) } }
        do {
            let prepared = try await installer.prepare(archiveURL: url)
            // Publish the review before releasing termination waiters. A
            // shutdown arriving during extraction cancels this exact stage;
            // cleanup failure retains the review for an explicit retry.
            review = prepared
            phase = .reviewing
            resumeIdleWaiters()
            return !isTerminating
        } catch {
            requiresCleanup = await installer.hasPendingCleanup()
            phase = .idle
            record(error, fallback: requiresCleanup ? "临时插件包无法清理，请重试清理。" : "插件包无法导入，请检查文件是否完整。")
            resumeIdleWaiters()
            return false
        }
    }

    public func rejectBusy() {
        if requiresCleanup {
            setError(code: "cleanupFailed", message: "临时插件包尚未清理，请先重试清理，再导入其他插件。")
        } else {
            setError(code: "busy", message: "已有一个插件正在导入。请先完成或取消当前安装，再重新导入其他插件。")
        }
    }

    public func install() async {
        guard !isTerminating, !isBusy, !requiresCleanup, let capturedReview = review else { return }
        phase = .installing
        clearError()
        do {
            let record = try await installer.commit(capturedReview)
            review = nil
            installedID = record.id
            await onInstalled?(record)
            phase = .idle
            resumeIdleWaiters()
        } catch {
            // A commit consumes its review even when rollback or marker
            // cleanup fails. Keeping it would strand the UI on a stale token.
            review = nil
            requiresCleanup = await installer.hasPendingCleanup()
            if (error as? PluginInstallerError)?.code == "cleanupFailed", !requiresCleanup {
                installedID = capturedReview.id
                setError(code: "cleanupFailed", message: "插件已安装并保持停用，但部分恢复文件未能清理。")
            } else {
                record(error, fallback: requiresCleanup ? "临时插件包无法清理，请重试清理。" : "插件安装失败，请重新导入。")
            }
            await onInstallFailure?(capturedReview, errorCode ?? "installFailed")
            phase = .idle
            resumeIdleWaiters()
        }
    }

    @discardableResult
    public func cancel() async -> Bool {
        guard !isBusy else { return false }
        guard let capturedReview = review else {
            if requiresCleanup { return await retryCleanup() }
            clearError()
            return true
        }
        phase = .cancelling
        clearError()
        do {
            try await installer.cancel(capturedReview)
            review = nil
            requiresCleanup = false
            phase = .idle
            resumeIdleWaiters()
            return true
        } catch {
            requiresCleanup = true
            phase = .reviewing
            record(error, fallback: "临时插件包无法清理，请重试取消。")
            resumeIdleWaiters()
            return false
        }
    }

    @discardableResult
    public func retryCleanup() async -> Bool {
        guard !isBusy else { return false }
        if review != nil { return await cancel() }
        phase = .cancelling
        clearError()
        do {
            try await installer.retryCleanup()
            requiresCleanup = await installer.hasPendingCleanup()
            guard !requiresCleanup else { throw PluginInstallerError.cleanupFailed }
            phase = .idle
            resumeIdleWaiters()
            return true
        } catch {
            requiresCleanup = true
            phase = .idle
            record(error, fallback: "临时插件包无法清理，请重试清理。")
            resumeIdleWaiters()
            return false
        }
    }

    @discardableResult
    public func shutdown() async -> Bool {
        isTerminating = true
        while isBusy { await withCheckedContinuation { idleWaiters.append($0) } }
        let cleaned = await cancel()
        if !cleaned { isTerminating = false }
        return cleaned
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func clearError() { errorMessage = nil; errorCode = nil }
    private func setError(code: String, message: String) { errorCode = code; errorMessage = message }
    private func record(_ error: Error, fallback: String) {
        guard let failure = error as? PluginInstallerError else {
            setError(code: "installFailed", message: fallback); return
        }
        let message: String
        switch failure.code {
        case "busy": message = "已有一个插件正在导入，请先完成或取消当前安装。"
        case "staleReview": message = "待安装插件或已安装版本发生变化，请重新导入。"
        case "incompatibleHost": message = "此插件需要较新的 Dynamic Island 版本，请更新主程序后重新导入。"
        case "quotaExceeded": message = "插件包超过允许的大小或文件数量，无法导入。"
        case "archiveRejected", "invalidPackage": message = "插件包损坏或不符合安全要求，无法导入。"
        case "rollbackFailed": message = "安装未完成，旧插件已停止并保留备份。请查看插件管理状态。"
        case "invalidArguments": message = "请选择有效的 .dip 插件包。"
        case "cancelled": message = "插件导入已取消。"
        default: message = fallback
        }
        // Codes are Host enum constants. Never expose localized underlying
        // errors, archive paths, script text, or filesystem diagnostics.
        setError(code: failure.code, message: message)
    }
}

/// File-open events can precede Host discovery. Keep a small startup queue,
/// then offer one immutable review at a time; further requests are rejected.
@MainActor
public final class PluginImportCoordinator {
    private var model: PluginInstallerModel?
    private var pending: [URL] = []
    private var deferredBusy = false
    private var drainTask: Task<Void, Never>?
    private var isTerminating = false
    private let onPresent: @MainActor () -> Void
    public let maximumPendingCount = 4
    public var pendingCount: Int { pending.count }

    public init(onPresent: @escaping @MainActor () -> Void) { self.onPresent = onPresent }

    public func enqueue(_ urls: [URL]) {
        guard !isTerminating else { return }
        for url in urls {
            if let model, model.hasPendingImport {
                model.rejectBusy()
                onPresent()
            } else if pending.count < maximumPendingCount {
                pending.append(url)
            } else {
                deferredBusy = true
            }
        }
        startDrain()
    }

    public func configure(model: PluginInstallerModel) {
        guard self.model == nil, !isTerminating else { return }
        self.model = model
        startDrain()
    }

    @discardableResult
    public func shutdown() async -> Bool {
        isTerminating = true
        pending.removeAll()
        let cleaned = await model?.shutdown() ?? true
        await drainTask?.value
        drainTask = nil
        if !cleaned { isTerminating = false }
        return cleaned
    }

    private func startDrain() {
        guard model != nil, drainTask == nil, !pending.isEmpty else { return }
        drainTask = Task { @MainActor [weak self] in
            guard let self, let model = self.model else { return }
            while !self.pending.isEmpty, !self.isTerminating {
                let url = self.pending.removeFirst()
                self.onPresent()
                if model.hasPendingImport { model.rejectBusy() }
                else { _ = await model.importArchive(url) }
                if self.deferredBusy { model.rejectBusy(); self.deferredBusy = false }
            }
            self.drainTask = nil
        }
    }
}

@MainActor
public struct PluginInstallerView: View {
    @Bindable private var model: PluginInstallerModel
    private let onCancel: @MainActor () -> Void

    public init(model: PluginInstallerModel, onCancel: @escaping @MainActor () -> Void) {
        self.model = model
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension").font(.title)
                VStack(alignment: .leading, spacing: 4) {
                    Text("安装插件").font(.title2.weight(.semibold))
                    Text("检查插件信息与权限").foregroundStyle(.secondary)
                }
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let message = model.errorMessage {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                            if let code = model.errorCode { Text("错误代码：\(code)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if let review = model.review { reviewDetails(review) }
                    else if model.phase == .preparing {
                        Text("正在检查插件包…").foregroundStyle(.secondary)
                    } else if model.installedID != nil {
                        Text("插件已安装并保持停用。请在插件管理中授权和启用。")
                    } else if model.errorMessage == nil {
                        Text("请选择一个 .dip 插件包。").foregroundStyle(.secondary)
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("安装不会授予权限或自动运行插件。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                if model.requiresCleanup, model.review == nil {
                    Button("重试清理") { Task { _ = await model.retryCleanup() } }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("plugin-installer-retry-cleanup")
                }
                Button(model.requiresCleanup && model.review != nil ? "重试取消" : (model.installedID == nil ? "取消" : "完成"), action: onCancel)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("plugin-installer-cancel")
                Button(model.review?.isUpgrade == true ? "替换并安装" : "安装插件") {
                    Task { await model.install() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.review == nil || model.isBusy || model.isTerminating || model.requiresCleanup)
                .accessibilityIdentifier("plugin-installer-confirm")
            }.padding(16)
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func reviewDetails(_ review: PluginInstallReview) -> some View {
        // Import previews describe only the reviewed package's validated
        // engine. They never borrow an installed execution's layout report.
        let compatibility = PluginCompatibilitySnapshot.profile(for: review.engine)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(review.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                Text("版本：\(review.version.description)")
                PluginCompatibilityBadge(snapshot: compatibility)
                    .font(.callout).foregroundStyle(.secondary)
                Text("开发者：\(review.developer ?? "未提供")（插件自行声明，未验证）")
                    .font(.callout).textSelection(.enabled)
                Text("插件 ID：\(review.id)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            PluginCompatibilityDetails(snapshot: compatibility)
            if let previous = review.previousVersion {
                Label(review.isDowngrade ? "将从 \(previous.description) 降级到 \(review.version.description)。旧版本会被替换。"
                      : "将替换当前版本 \(previous.description)。",
                      systemImage: review.isDowngrade ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(review.isDowngrade ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("替换后插件保持停用，代码或权限声明变化后的授权需要重新确认。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            Text("插件声明的权限").font(.headline)
            if review.permissions.isEmpty { Text("此插件未申请权限。").foregroundStyle(.secondary) }
            ForEach(review.permissions.sorted { $0.rawValue < $1.rawValue }, id: \.self) { permission in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(PluginPermissionPresentation.title(permission)).font(.callout.weight(.medium))
                        Spacer()
                        Text(PluginExtensionsModel.supports(permission) ? "安装后另行授权" : "此版本尚未支持")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(PluginPermissionPresentation.explanation(permission))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

@MainActor
public final class PluginInstallerWindowController: NSWindowController, NSWindowDelegate {
    private let model: PluginInstallerModel
    private var completingClose = false

    public convenience init(model: PluginInstallerModel) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 680, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        self.init(model: model, eventWindow: window)
    }

    init(model: PluginInstallerModel, eventWindow window: NSWindow) {
        self.model = model
        window.title = "安装插件"
        window.contentMinSize = CGSize(width: 640, height: 520)
        window.minSize = window.frameRect(forContentRect: CGRect(x: 0, y: 0, width: 640, height: 520)).size
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let hostingView = NSHostingView(rootView: PluginInstallerView(model: model, onCancel: { [weak self] in
            self?.requestCancel()
        }))
        hostingView.frame = CGRect(x: 0, y: 0, width: 680, height: 600)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    public func show() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        if !(window is NSPanel) { NSApp.activate() }
        window.makeKeyAndOrderFront(nil)
    }

    public func finishClose() {
        completingClose = true
        close()
        completingClose = false
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if completingClose { return true }
        requestCancel()
        return false
    }

    private func requestCancel() {
        guard !model.isBusy else { return }
        Task { @MainActor [weak self] in
            guard let self, await self.model.cancel() else { return }
            self.finishClose()
        }
    }
}
