import Combine
import Foundation

@MainActor
public final class IslandHomeSettings: ObservableObject {
    public nonisolated static let showsLayerButtonsKey = "island.home.showsLayerButtons"
    public nonisolated static let defaultLayerKey = "island.home.defaultLayer"

    @Published public var showsLayerButtons: Bool {
        didSet { defaults.set(showsLayerButtons, forKey: Self.showsLayerButtonsKey) }
    }

    @Published public var defaultLayer: IslandHomeLayer {
        didSet { defaults.set(defaultLayer.rawValue, forKey: Self.defaultLayerKey) }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsLayerButtons = defaults.object(forKey: Self.showsLayerButtonsKey) as? Bool ?? true
        defaultLayer = defaults.string(forKey: Self.defaultLayerKey)
            .flatMap(IslandHomeLayer.init(rawValue:)) ?? .music
    }
}
