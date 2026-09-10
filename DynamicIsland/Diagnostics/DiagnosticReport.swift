import CoreGraphics
import Darwin
import Foundation

nonisolated struct DiagnosticSystemInfo: Equatable, Sendable {
    let appName: String
    let appVersion: String
    let buildNumber: String
    let operatingSystem: String
    let hardwareModel: String
    let processArchitecture: String

    static func current(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> DiagnosticSystemInfo {
        DiagnosticSystemInfo(
            appName: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? "Dynamic Island",
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "unknown",
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "unknown",
            operatingSystem: processInfo.operatingSystemVersionString,
            hardwareModel: sysctlString(named: "hw.model") ?? "unknown",
            processArchitecture: architectureName
        )
    }

    private static var architectureName: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }

    private static func sysctlString(named name: String) -> String? {
        var size = 0
        let sizeResult = name.withCString { pointer in
            sysctlbyname(pointer, nil, &size, nil, 0)
        }
        guard sizeResult == 0, size > 0 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        let readResult = buffer.withUnsafeMutableBytes { bytes in
            name.withCString { pointer in
                sysctlbyname(pointer, bytes.baseAddress, &size, nil, 0)
            }
        }
        guard readResult == 0 else {
            return nil
        }

        let value = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return value.isEmpty ? nil : value
    }
}

nonisolated struct DiagnosticIslandState: Equatable, Sendable {
    let presentationState: String
    let expandedSurface: String
    let compactPanelSize: CGSize
    let panelFrame: CGRect?
    let isPanelVisible: Bool
    let isMusicPlaying: Bool
    let timerSession: String
    let trayItemCount: Int
}

nonisolated struct DynamicIslandDiagnosticReport: Equatable, Sendable {
    static let schemaVersion = 1

    let generatedAt: String
    let system: DiagnosticSystemInfo
    let selectionPolicy: String
    let simulationEnabled: Bool
    let activeDisplayID: CGDirectDisplayID?
    let screens: [ScreenEnvironment]
    let island: DiagnosticIslandState

    var renderedText: String {
        var lines = [
            "Dynamic Island Diagnostic Report",
            "schema_version: \(Self.schemaVersion)",
            "generated_at: \(singleLine(generatedAt))",
            "app: \(singleLine(system.appName)) \(singleLine(system.appVersion)) (\(singleLine(system.buildNumber)))",
            "macos: \(singleLine(system.operatingSystem))",
            "hardware_model: \(singleLine(system.hardwareModel))",
            "process_architecture: \(singleLine(system.processArchitecture))",
            "screen_selection: \(singleLine(selectionPolicy))",
            "simulation: \(yesNo(simulationEnabled))",
            "screen_count: \(screens.count)",
            "active_display_id: \(activeDisplayID.map(String.init) ?? "none")",
            "panel_visible: \(yesNo(island.isPanelVisible))",
            "panel_frame_points: \(island.panelFrame.map(rectDescription) ?? "none")",
            "compact_panel_size_points: \(sizeDescription(island.compactPanelSize))",
            "presentation_state: \(singleLine(island.presentationState))",
            "expanded_surface: \(singleLine(island.expandedSurface))",
            "music_playing: \(yesNo(island.isMusicPlaying))",
            "timer_session: \(singleLine(island.timerSession))",
            "tray_item_count: \(island.trayItemCount)",
            "",
            "screens:",
        ]

        if screens.isEmpty {
            lines.append("- none")
        } else {
            for (index, screen) in screens.enumerated() {
                let activeMarker = screen.displayID == activeDisplayID ? " active" : ""
                let reservedTopHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
                let estimatedPixelSize = CGSize(
                    width: screen.frame.width * screen.backingScaleFactor,
                    height: screen.frame.height * screen.backingScaleFactor
                )
                lines.append("- display_\(index + 1):\(activeMarker)")
                lines.append("  name: \(singleLine(screen.name))")
                lines.append("  id: \(screen.displayID)")
                lines.append("  built_in: \(yesNo(screen.isBuiltIn))")
                lines.append("  notch: \(yesNo(screen.hasNotch))")
                lines.append("  scale_factor: \(number(screen.backingScaleFactor))")
                lines.append("  frame_points: \(rectDescription(screen.frame))")
                lines.append("  visible_frame_points: \(rectDescription(screen.visibleFrame))")
                lines.append("  estimated_pixels: \(sizeDescription(estimatedPixelSize))")
                lines.append("  safe_area_points: \(insetsDescription(screen.safeAreaInsets))")
                lines.append("  auxiliary_top_left_points: \(rectDescription(screen.auxiliaryTopLeftArea))")
                lines.append("  auxiliary_top_right_points: \(rectDescription(screen.auxiliaryTopRightArea))")
                lines.append("  top_reserved_height_points: \(number(reservedTopHeight))")
            }
        }

        lines.append("")
        lines.append("privacy: excludes usernames, serial numbers, file names, and track metadata")
        return lines.joined(separator: "\n")
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private func rectDescription(_ rect: CGRect) -> String {
        "x=\(number(rect.origin.x)) y=\(number(rect.origin.y)) width=\(number(rect.width)) height=\(number(rect.height))"
    }

    private func sizeDescription(_ size: CGSize) -> String {
        "width=\(number(size.width)) height=\(number(size.height))"
    }

    private func insetsDescription(_ insets: ScreenEdgeInsets) -> String {
        "top=\(number(insets.top)) left=\(number(insets.left)) bottom=\(number(insets.bottom)) right=\(number(insets.right))"
    }

    private func number(_ value: CGFloat) -> String {
        guard value.isFinite else {
            return "nonfinite"
        }
        return String(format: "%.1f", Double(value))
    }

    private func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
