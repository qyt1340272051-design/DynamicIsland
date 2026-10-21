import Foundation

/// Host-only display values. No wall-clock timestamp or per-second VM request
/// is needed to draw the retained continuous countdown.
nonisolated extension PluginCountdownSnapshot {
    var displayText: String {
        let milliseconds = remainingMilliseconds
        let seconds = (milliseconds + 999) / 1_000
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainder) }
        return String(format: "%02d:%02d", minutes, remainder)
    }

    var elapsedFraction: Double {
        let parts = max(.zero, remaining).components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return min(1, max(0, 1 - seconds / (Double(durationMilliseconds) / 1_000)))
    }

    var requiresDisplayTick: Bool { state == .running && remaining > .zero }
}
