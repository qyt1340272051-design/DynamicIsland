import CoreGraphics
import XCTest
@testable import DynamicIsland

final class DiagnosticReportTests: XCTestCase {
    func testRenderedReportContainsUsefulDisplayContextWithoutPrivateContent() {
        let report = makeReport()

        XCTAssertTrue(report.renderedText.contains("schema_version: 1"))
        XCTAssertTrue(report.renderedText.contains("app: Dynamic Island 0.4.0 (42)"))
        XCTAssertTrue(report.renderedText.contains("hardware_model: Mac16,12"))
        XCTAssertTrue(report.renderedText.contains("process_architecture: arm64"))
        XCTAssertTrue(report.renderedText.contains("active_display_id: 7"))
        XCTAssertTrue(report.renderedText.contains("built_in: yes"))
        XCTAssertTrue(report.renderedText.contains("notch: yes"))
        XCTAssertTrue(report.renderedText.contains("scale_factor: 2.0"))
        XCTAssertTrue(report.renderedText.contains("estimated_pixels: width=3024.0 height=1964.0"))
        XCTAssertTrue(report.renderedText.contains("presentation_state: compact"))
        XCTAssertTrue(report.renderedText.contains("privacy: excludes usernames, serial numbers, file names, and track metadata"))
        XCTAssertFalse(report.renderedText.contains("/Users/example"))
        XCTAssertFalse(report.renderedText.contains("private-track-title"))
        XCTAssertFalse(report.renderedText.contains("private-file-name"))
        XCTAssertFalse(report.renderedText.contains("serial_number:"))
    }

    @MainActor
    func testCopyWritesRenderedReportToClipboard() {
        let clipboard = DiagnosticClipboardMock()
        let service = DiagnosticReportService(clipboard: clipboard)
        let report = makeReport()

        XCTAssertTrue(service.copy(report))
        XCTAssertEqual(clipboard.writtenText, report.renderedText)
    }

    func testBetaFeedbackURLTargetsRepositoryIssueForm() {
        let components = URLComponents(
            url: BetaFeedbackConfiguration.issueURL,
            resolvingAgainstBaseURL: false
        )

        XCTAssertEqual(components?.host, "github.com")
        XCTAssertEqual(components?.path, "/qyt1340272051-design/DynamicIsland/issues/new")
        XCTAssertEqual(components?.queryItems, [
            URLQueryItem(name: "template", value: "beta_feedback.yml"),
        ])
    }

    private func makeReport() -> DynamicIslandDiagnosticReport {
        let screen = ScreenEnvironment(
            displayID: 7,
            name: "Built-in Display",
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 40, width: 1512, height: 918),
            safeAreaInsets: ScreenEdgeInsets(top: 38),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 616, height: 38),
            auxiliaryTopRightArea: CGRect(x: 896, y: 944, width: 616, height: 38),
            backingScaleFactor: 2,
            isBuiltIn: true
        )

        return DynamicIslandDiagnosticReport(
            generatedAt: "2026-09-10T12:00:00.000Z",
            system: DiagnosticSystemInfo(
                appName: "Dynamic Island",
                appVersion: "0.4.0",
                buildNumber: "42",
                operatingSystem: "macOS 26.0 (25A)",
                hardwareModel: "Mac16,12",
                processArchitecture: "arm64"
            ),
            selectionPolicy: "built-in",
            simulationEnabled: false,
            activeDisplayID: screen.displayID,
            screens: [screen],
            island: DiagnosticIslandState(
                presentationState: "compact",
                expandedSurface: "music",
                compactPanelSize: CGSize(width: 260, height: 24),
                panelFrame: CGRect(x: 626, y: 958, width: 260, height: 24),
                isPanelVisible: true,
                isMusicPlaying: false,
                timerSession: "none",
                trayItemCount: 0
            )
        )
    }
}

@MainActor
private final class DiagnosticClipboardMock: DiagnosticClipboard {
    private(set) var writtenText: String?

    func write(_ text: String) -> Bool {
        writtenText = text
        return true
    }
}
