import AppKit
import Foundation

/// One Host-owned Activity graph for the production island. Providers publish
/// data to the manager; visible actions return through the same router.
@MainActor
public final class IslandActivityRuntime {
    public let manager: ActivityManager
    public let router: ActionRouter
    public let pluginLifecycle: PluginLifecycleBridge
    private let music: MusicActivityProvider
    private let volume: VolumeActivityProvider
    private let battery: BatteryActivityProvider?

    private let musicRegistration: UUID

    public init(
        viewModel: IslandViewModel,
        batteryService: (any BatteryService)? = nil,
        batteryDebounceNanoseconds: UInt64 = BatteryActivityProvider.defaultDebounceNanoseconds
    ) {
        let manager = ActivityManager()
        let router = ActionRouter(manager: manager)
        let pluginLifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: router)
        let music = MusicActivityProvider(viewModel: viewModel, manager: manager)
        let volume = VolumeActivityProvider(viewModel: viewModel, manager: manager)
        let battery = batteryService.map {
            BatteryActivityProvider(
                service: $0,
                manager: manager,
                debounceNanoseconds: batteryDebounceNanoseconds
            )
        }

        self.manager = manager
        self.router = router
        self.pluginLifecycle = pluginLifecycle
        self.music = music
        self.volume = volume
        self.battery = battery
        musicRegistration = music.registerActions(with: router)
    }

    public var isCompactActivityVisible: Bool {
        manager.currentSnapshot?.activity.presentation.isCompactVisible == true
    }

    /// Only the Host-owned Battery Activity needs enough side clearance to
    /// keep both status groups outside a physical camera notch.
    public var currentActivityUsesBatteryCompactLayout: Bool {
        guard let activity = manager.currentSnapshot?.activity else { return false }
        return activity.id == BatteryActivityProvider.activityID
            && activity.source == BatteryActivityProvider.source
    }

    /// Volume keeps its glyph and widest percentage label in the two display
    /// wings while the physical notch occupies the center of the shell.
    public var currentActivityUsesVolumeCompactLayout: Bool {
        guard let activity = manager.currentSnapshot?.activity else { return false }
        return activity.id == VolumeActivityProvider.activityID
            && activity.source == VolumeActivityProvider.source
    }

    /// Transient and critical built-ins temporarily replace legacy timer or
    /// tray content. Persistent music remains tied to the selected music tab.
    public var prioritizesCurrentActivityOverLegacyContent: Bool {
        guard let snapshot = manager.currentSnapshot else { return false }
        return snapshot.activity.source != MusicActivityProvider.source
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
