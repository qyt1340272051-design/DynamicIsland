import AppKit
import SwiftUI

/// Keep SwiftUI's native Settings window delegate in the responder chain,
/// while preserving the installer's asynchronous close and cleanup contract.
@MainActor
final class AppSettingsWindowCoordinator: NSObject, NSWindowDelegate {
    private let installer: () -> PluginInstallerModel?
    private let onShowInstaller: () -> Void
    private let onClose: () -> Void
    private weak var window: NSWindow?
    private weak var forwardedDelegate: (any NSWindowDelegate)?
    private var cancellationTask: Task<Void, Never>?
    private var completingClose = false

    init(installer: @escaping () -> PluginInstallerModel?,
         onShowInstaller: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self.installer = installer
        self.onShowInstaller = onShowInstaller
        self.onClose = onClose
    }

    func attach(to window: NSWindow) {
        guard window.delegate !== self else { return }
        self.window = window
        forwardedDelegate = window.delegate
        window.delegate = self
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (forwardedDelegate?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if forwardedDelegate?.responds(to: selector) == true { return forwardedDelegate }
        return super.forwardingTarget(for: selector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !completingClose, let model = installer(), model.hasPendingImport else {
            return forwardedDelegate?.windowShouldClose?(sender) ?? true
        }
        onShowInstaller()
        guard cancellationTask == nil, !model.isBusy || model.canCancelDownload else { return false }
        cancellationTask = Task { @MainActor [weak self] in
            let cancelled = await model.cancel()
            guard let self else { return }
            self.cancellationTask = nil
            guard cancelled, let window = self.window else { return }
            self.completingClose = true
            window.performClose(nil)
            self.completingClose = false
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
        forwardedDelegate?.windowWillClose?(notification)
    }
}

/// Resolve the real window after SwiftUI attaches the Settings scene.
struct AppSettingsWindowReader: NSViewRepresentable {
    let onResolve: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowReaderView {
        WindowReaderView(onResolve: onResolve)
    }

    func updateNSView(_ view: WindowReaderView, context: Context) {
        view.onResolve = onResolve
        view.resolveWindow()
    }

    final class WindowReaderView: NSView {
        var onResolve: @MainActor (NSWindow) -> Void

        init(onResolve: @escaping @MainActor (NSWindow) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveWindow()
        }

        func resolveWindow() {
            if let window { onResolve(window) }
        }
    }
}
