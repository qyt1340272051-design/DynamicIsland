import SwiftUI

private struct IslandLayoutScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// Host design points to actual display points. This does not describe
    /// backing pixels and does not change the plugin's finite visual tokens.
    var islandLayoutScale: CGFloat {
        get { self[IslandLayoutScaleKey.self] }
        set { self[IslandLayoutScaleKey.self] = newValue.isFinite && newValue > 0 ? newValue : 1 }
    }
}
