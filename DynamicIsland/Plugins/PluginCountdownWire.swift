import Foundation

nonisolated extension PluginCountdownSnapshot {
    /// Round only the wire/display value up. Broker pause/resume keeps Duration.
    var remainingMilliseconds: Int {
        let value = max(.zero, remaining).components
        let fractional = (value.attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
        return min(durationMilliseconds, max(0, Int(value.seconds) * 1_000 + Int(fractional)))
    }

    var bridgeJSON: PluginBridgeJSON {
        let stateName: String
        switch state {
        case .running: stateName = "running"
        case .paused: stateName = "paused"
        case .completed: stateName = "completed"
        }
        return .object([
            "id": .string(id), "generation": .string(generation.rawValue), "state": .string(stateName),
            "durationMs": .number(Double(durationMilliseconds)),
            "remainingMs": .number(Double(remainingMilliseconds))
        ])
    }
}
