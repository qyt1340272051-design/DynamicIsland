import AppKit
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class CalendarAgendaUITests: XCTestCase {
    func testTimeLabelsRespectAllDayAndStartEndBoundaries() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func event(start: TimeInterval, end: TimeInterval, allDay: Bool = false) -> AgendaEvent {
            .init(id: "fixture", title: "Fixture", startDate: now.addingTimeInterval(start),
                  endDate: now.addingTimeInterval(end), isAllDay: allDay, calendarID: "calendar")
        }
        XCTAssertEqual(AgendaEventTimeLabel.relativeLabel(for: event(start: 0, end: 60), now: now), "进行中")
        XCTAssertEqual(AgendaEventTimeLabel.relativeLabel(for: event(start: -60, end: 0), now: now), "已结束")
        XCTAssertEqual(AgendaEventTimeLabel.relativeLabel(for: event(start: 59, end: 300), now: now), "即将开始")
        XCTAssertEqual(AgendaEventTimeLabel.relativeLabel(for: event(start: 61, end: 300), now: now), "2 分钟后")
        XCTAssertEqual(AgendaEventTimeLabel.relativeLabel(for: event(start: -60, end: 60, allDay: true), now: now), "全天")
    }

    func testMeetingControlsOnlyOpenWebURLs() {
        for value in ["https://meet.google.com/abc-defg-hij", "http://example.com/meeting"] {
            XCTAssertTrue(AgendaEventTimeLabel.isOpenableMeetingURL(URL(string: value)!))
        }
        for value in ["file:///tmp/calendar", "javascript:alert(1)", "https:missing-host", "zoommtg://zoom.us/join"] {
            XCTAssertFalse(AgendaEventTimeLabel.isOpenableMeetingURL(URL(string: value)!))
        }
    }

    func testAgendaFitsTwoRowsAndFiltersCourseAndMeetingLayers() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        await fixture.model.refresh()
        let window = makeWindow(size: CGSize(width: 412, height: 122))
        defer { window.close() }

        window.contentView = NSHostingView(rootView: IslandAgendaView(model: fixture.model, filter: nil,
            onOpenSettings: {}).background(.black))
        window.orderFrontRegardless()
        try await settle(window)
        let agenda = try renderedText(window, name: "agenda-all")
        XCTAssertTrue(agenda.contains("项目会议"), agenda)
        XCTAssertTrue(agenda.contains("高等数学"), agenda)

        window.contentView = NSHostingView(rootView: IslandAgendaView(model: fixture.model, filter: .course,
            onOpenSettings: {}).background(.black))
        try await settle(window)
        let course = try renderedText(window, name: "agenda-course")
        XCTAssertTrue(course.contains("高等数学"), course)
        XCTAssertFalse(course.contains("项目会议"), course)

        window.contentView = NSHostingView(rootView: IslandAgendaView(model: fixture.model, filter: .meeting,
            onOpenSettings: {}).background(.black))
        try await settle(window)
        let meeting = try renderedText(window, name: "agenda-meeting")
        XCTAssertTrue(meeting.contains("项目会议"), meeting)
        XCTAssertFalse(meeting.contains("高等数学"), meeting)
    }

    func testSettingsShowAppleAndGoogleCalendarsAndClassificationWithoutPrompting() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        await fixture.model.refresh()
        let settings = AppSettingsModel(selectedTab: .calendar)
        settings.calendarAgenda = fixture.model
        let window = makeWindow(size: AppSettingsView.minimumContentSize)
        defer { window.close() }
        window.contentView = NSHostingView(rootView: AppSettingsView(model: settings, onImport: {},
            onDownload: { _ in }, onCancelInstall: {}, onShowIsland: {}, onHideIsland: {}, onCopyDiagnosticInfo: {}))
        window.orderFrontRegardless()
        try await settle(window)
        let text = try renderedText(window, name: "calendar-settings")
        for title in ["日历与提醒", "Apple 日历", "Google 日历", "高等数学课表", "工作会议", "分类"] {
            XCTAssertTrue(text.contains(title), "Missing \(title): \(text)")
        }
        let requests = await fixture.service.authorizationRequests
        XCTAssertEqual(requests, 0, "Opening settings must not request calendar access.")
        XCTAssertEqual(fixture.scheduler.authorizationRequests, 0, "Opening settings must not request notifications.")
    }

    func testPermissionEmptyStateFitsTheAgendaCanvasWithoutPrompting() async throws {
        let fixture = try makeFixture(authorization: .notDetermined)
        defer { fixture.cleanup() }
        await fixture.model.refresh()
        let window = makeWindow(size: CGSize(width: 412, height: 122))
        defer { window.close() }
        window.contentView = NSHostingView(rootView: IslandAgendaView(model: fixture.model, filter: nil,
            onOpenSettings: {}).background(.black))
        window.orderFrontRegardless()
        try await settle(window)
        let text = try renderedText(window, name: "agenda-permission")
        XCTAssertTrue(text.contains("连接你的日历"), text)
        XCTAssertTrue(text.contains("连接日历"), text)
        let requests = await fixture.service.authorizationRequests
        XCTAssertEqual(requests, 0)
    }

    private func makeFixture(authorization: CalendarAuthorization = .authorized) throws -> CalendarAgendaUIFixture {
        let suite = "CalendarAgendaUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let now = Date.now
        let snapshot = AgendaStoreSnapshot(calendars: [
            .init(id: "google", title: "工作会议", sourceTitle: "Google", source: .google),
            .init(id: "apple", title: "高等数学课表", sourceTitle: "iCloud", source: .apple)
        ], events: [
            .init(id: "meeting", title: "项目会议", startDate: now.addingTimeInterval(600),
                  endDate: now.addingTimeInterval(3600), location: "会议室 A", calendarID: "google", kind: .meeting,
                  meetingURL: URL(string: "https://meet.google.com/abc-defg-hij")),
            .init(id: "course", title: "高等数学", startDate: now.addingTimeInterval(7200),
                  endDate: now.addingTimeInterval(10_800), location: "教学楼 301", calendarID: "apple", kind: .course)
        ])
        let service = CalendarAgendaUIService(status: authorization, snapshot: snapshot)
        let scheduler = CalendarAgendaUIScheduler()
        let model = CalendarAgendaModel(defaults: defaults, service: service, scheduler: scheduler, now: { now })
        return CalendarAgendaUIFixture(model: model, service: service, scheduler: scheduler,
            cleanup: { model.stop(); defaults.removePersistentDomain(forName: suite) })
    }

    private func makeWindow(size: CGSize) -> NSPanel {
        let window = NSPanel(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.center()
        return window
    }

    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
    }

    private func renderedText(_ window: NSWindow, name: String) throws -> String {
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try CompatibilityRenderingEvidence.bitmap(in: view)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("dynamic-island-\(name).png")
        try png.write(to: output)
        print("CALENDAR_UI_SCREENSHOT=\(output.path)")
        return try CompatibilityRenderingEvidence.renderedText(in: view)
    }
}

@MainActor
private struct CalendarAgendaUIFixture {
    let model: CalendarAgendaModel
    let service: CalendarAgendaUIService
    let scheduler: CalendarAgendaUIScheduler
    let cleanup: () -> Void
}

private actor CalendarAgendaUIService: AgendaCalendarService {
    let status: CalendarAuthorization
    let snapshot: AgendaStoreSnapshot
    private(set) var authorizationRequests = 0

    init(status: CalendarAuthorization, snapshot: AgendaStoreSnapshot) {
        self.status = status
        self.snapshot = snapshot
    }

    func authorization() -> CalendarAuthorization { status }
    func requestAccess() -> Bool { authorizationRequests += 1; return status == .authorized }
    func fetch(from start: Date, to end: Date) -> AgendaStoreSnapshot { snapshot }
}

@MainActor
private final class CalendarAgendaUIScheduler: AgendaReminderScheduling {
    private(set) var authorizationRequests = 0
    func requestAuthorization() -> Bool { authorizationRequests += 1; return true }
    func isAuthorized() -> Bool { true }
    func replace(_ reminders: [AgendaReminder]) {}
    func clear() {}
}
