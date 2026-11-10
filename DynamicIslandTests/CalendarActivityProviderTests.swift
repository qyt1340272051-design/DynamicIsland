import XCTest
@testable import DynamicIsland

final class CalendarActivityProviderTests: XCTestCase {
    @MainActor
    func testCalendarReminderDefersToFileDropAndTimerCompletion() throws {
        let model = IslandViewModel.preview()
        let runtime = IslandActivityRuntime(viewModel: model)
        let now = Date()
        let event = AgendaEvent(id: "upcoming", title: "课程", startDate: now.addingTimeInterval(60),
            endDate: now.addingTimeInterval(3_600), calendarID: "course", kind: .course)
        try runtime.manager.publish(CalendarActivityProvider.makeActivity(for: event, createdAt: now))
        XCTAssertTrue(runtime.prioritizesCurrentActivityOverLegacyContent)
        model.setDragging(true)
        XCTAssertFalse(runtime.prioritizesCurrentActivityOverLegacyContent)
        XCTAssertEqual(model.expandedSurface, .fileTray)
        model.setDragging(false)
        XCTAssertTrue(runtime.prioritizesCurrentActivityOverLegacyContent)

        model.timerTools.selectedMode = .countdown
        model.timerTools.startSelectedTimer(at: now)
        model.timerTools.refresh(at: now.addingTimeInterval(model.timerTools.countdownDuration))
        XCTAssertTrue(model.isTimerCompletionPresented)
        XCTAssertFalse(runtime.prioritizesCurrentActivityOverLegacyContent)
        XCTAssertEqual(model.expandedSurface, .tools)
    }

    func testReminderHasFiniteLifetimeAndFitsHostLayouts() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = AgendaEvent(id: "recurring:2", title: String(repeating: "课程名称", count: 60),
            startDate: now.addingTimeInterval(600), endDate: now.addingTimeInterval(3_600),
            location: String(repeating: "教室", count: 120), calendarID: "courses", kind: .course)
        let activity = CalendarActivityProvider.makeActivity(for: event, createdAt: now)
        XCTAssertEqual(activity.source, CalendarActivityProvider.source)
        XCTAssertEqual(activity.lifecycle.policy, .transient)
        XCTAssertEqual(activity.priority, .important)
        XCTAssertEqual(activity.expiresAt, now.addingTimeInterval(12))
        XCTAssertEqual(activity.presentation.symbolName, "book.closed")
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(try XCTUnwrap(activity.presentation.compact), for: .compact))
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(try XCTUnwrap(activity.presentation.expanded), for: .expanded))
    }

    func testEachOccurrenceKeepsDistinctIdentityAndLateStartDoesNotShowNegativeMinutes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ id: String) -> AgendaEvent {
            .init(id: id, title: "会议", startDate: now.addingTimeInterval(-10),
                  endDate: now.addingTimeInterval(600), calendarID: "work", kind: .meeting)
        }
        let first = CalendarActivityProvider.makeActivity(for: event("meeting:1"), createdAt: now)
        let second = CalendarActivityProvider.makeActivity(for: event("meeting:2"), createdAt: now)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.presentation.subtitle, "即将开始")
    }
}
