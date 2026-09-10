import AppKit
import Foundation

@MainActor
protocol DiagnosticClipboard {
    func write(_ text: String) -> Bool
}

@MainActor
final class SystemDiagnosticClipboard: DiagnosticClipboard {
    func write(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

nonisolated enum BetaFeedbackConfiguration {
    static let issueURL = URL(
        string: "https://github.com/qyt1340272051-design/DynamicIsland/issues/new?template=beta_feedback.yml"
    )!
}

@MainActor
final class DiagnosticReportService {
    private let clipboard: DiagnosticClipboard

    init() {
        clipboard = SystemDiagnosticClipboard()
    }

    init(clipboard: DiagnosticClipboard) {
        self.clipboard = clipboard
    }

    func makeReport(
        screenManager: ScreenManager,
        viewModel: IslandViewModel,
        panelFrame: CGRect?,
        isPanelVisible: Bool,
        generatedAt: Date = Date()
    ) -> DynamicIslandDiagnosticReport {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return DynamicIslandDiagnosticReport(
            generatedAt: formatter.string(from: generatedAt),
            system: .current(),
            selectionPolicy: description(of: screenManager.selectionPolicy),
            simulationEnabled: screenManager.simulationConfiguration != nil,
            activeDisplayID: screenManager.activeScreen?.displayID,
            screens: screenManager.screens,
            island: DiagnosticIslandState(
                presentationState: description(of: viewModel.presentationState),
                expandedSurface: description(of: viewModel.expandedSurface),
                compactPanelSize: viewModel.compactPanelSize,
                panelFrame: panelFrame,
                isPanelVisible: isPanelVisible,
                isMusicPlaying: viewModel.isPlaying,
                timerSession: viewModel.compactTimerMode?.rawValue ?? "none",
                trayItemCount: viewModel.trayItems.count
            )
        )
    }

    @discardableResult
    func copy(_ report: DynamicIslandDiagnosticReport) -> Bool {
        clipboard.write(report.renderedText)
    }

    @discardableResult
    func makeAndCopyReport(
        screenManager: ScreenManager,
        viewModel: IslandViewModel,
        panelFrame: CGRect?,
        isPanelVisible: Bool
    ) -> Bool {
        copy(makeReport(
            screenManager: screenManager,
            viewModel: viewModel,
            panelFrame: panelFrame,
            isPanelVisible: isPanelVisible
        ))
    }

    private func description(of policy: ScreenSelectionPolicy) -> String {
        switch policy {
        case .builtIn:
            return "built-in"
        case .main:
            return "main"
        case .display(let displayID):
            return "display:\(displayID)"
        }
    }

    private func description(of state: IslandPresentationState) -> String {
        switch state {
        case .compact:
            return "compact"
        case .expanded:
            return "expanded"
        case .dragging:
            return "dragging"
        }
    }

    private func description(of surface: IslandExpandedSurface) -> String {
        switch surface {
        case .music:
            return "music"
        case .fileTray:
            return "file-tray"
        case .tools:
            return "tools"
        }
    }
}
