import AppKit
import Foundation

/// One Host-owned Activity graph for the production island. Providers publish
/// data to the manager; visible actions return through the same router.
@MainActor
public final class IslandActivityRuntime {
    public let manager: ActivityManager
    public let router: ActionRouter
    private let music: MusicActivityProvider

    private let musicRegistration: UUID

    public init(viewModel: IslandViewModel) {
        let manager = ActivityManager()
        let router = ActionRouter(manager: manager)
        let music = MusicActivityProvider(viewModel: viewModel, manager: manager)

        self.manager = manager
        self.router = router
        self.music = music
        musicRegistration = music.registerActions(with: router)
    }

    public var isCompactActivityVisible: Bool {
        manager.currentSnapshot?.activity.presentation.isCompactVisible == true
    }

    /// Resources are resolved by the Host for the owning source. Providers do
    /// not hand filesystem paths or URLs to the renderer.
    public func resolveImage(_ image: IslandNode.ImageSource, for source: ActivitySource) -> NSImage? {
        switch source {
        case MusicActivityProvider.source:
            return music.resolveImage(image)
        default:
            return nil
        }
    }
}
