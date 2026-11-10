import Foundation
import XCTest
@testable import DynamicIsland

final class CalendarReminderPlanTests: XCTestCase {
    func testPlanSortsCapsDeduplicatesAndSkipsAllDayAndPastFireDates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ id: String, after seconds: Double, allDay: Bool = false) -> AgendaEvent {
            AgendaEvent(id: id, title: id, startDate: now.addingTimeInterval(seconds),
                endDate: now.addingTimeInterval(seconds + 3_600), isAllDay: allDay, calendarID: "cal")
        }
        let next = event("next", after: 1_200)
        var events = (0..<60).map { event("event\($0)", after: Double(3_000 + $0 * 60)) }.reversed().map { $0 }
        events += [event("pastFireDate", after: 100), event("allDay", after: 2_000, allDay: true), next, next]
        let plan = AgendaReminderPlan.reminders(events: events, leadMinutes: 10, now: now)
        XCTAssertEqual(plan.count, 50)
        XCTAssertEqual(plan.first?.event.id, "next")
        XCTAssertEqual(plan.first?.fireDate, now.addingTimeInterval(600))
        XCTAssertEqual(Set(plan.map(\.identifier)).count, 50)
        XCTAssertFalse(plan.contains { $0.event.isAllDay || $0.event.id == "pastFireDate" })
    }

    func testRecurringOccurrencesReceiveDistinctStableReminderIdentifiers() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func reminder(_ id: String, date: Date) -> AgendaReminder {
            .init(event: .init(id: id, title: "课程", startDate: date,
                endDate: date.addingTimeInterval(3_600), calendarID: "cal"), fireDate: date)
        }
        let first = reminder("series:1", date: start)
        XCTAssertEqual(first.identifier, reminder("series:1", date: start).identifier)
        XCTAssertNotEqual(first.identifier, reminder("series:2", date: start.addingTimeInterval(86_400)).identifier)
    }

    func testCalendarKindSuggestionsAndMeetingURLHostValidation() {
        XCTAssertEqual(AgendaEventKind.suggested(forCalendarTitle: "大学课表"), .course)
        XCTAssertEqual(AgendaEventKind.suggested(forCalendarTitle: "Team Meetings"), .meeting)
        XCTAssertEqual(AgendaEventKind.suggested(forCalendarTitle: "个人"), .event)
        let legitimate = URL(string: "https://meet.google.com/abc-defg-hij")!
        XCTAssertEqual(EventKitCalendarService.meetingURL(url: legitimate, notes: nil), legitimate)
        XCTAssertNil(EventKitCalendarService.meetingURL(url: URL(string: "https://zoom.us.attacker.test/abc"), notes: nil))
        XCTAssertNil(EventKitCalendarService.meetingURL(url: URL(string: "file:///tmp/meet.google.com"), notes: nil))
        XCTAssertEqual(EventKitCalendarService.meetingURL(url: nil, notes: "加入会议：\(legitimate.absoluteString)"), legitimate)
    }
}
