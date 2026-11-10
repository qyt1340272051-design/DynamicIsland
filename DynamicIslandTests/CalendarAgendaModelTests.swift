import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class CalendarAgendaModelTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendar = AgendaCalendar(id: "apple", title: "个人", sourceTitle: "iCloud", source: .apple)

    func testRefreshNeverRequestsPermissionAndHidesUnauthorizedData() async throws {
        let fixture = try makeFixture(status: .notDetermined)
        defer { fixture.clean() }
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.authorization, .notDetermined)
        XCTAssertTrue(fixture.model.events.isEmpty)
        let counts = await fixture.service.counts()
        XCTAssertEqual(counts.requests, 0)
        XCTAssertEqual(counts.fetches, 0)
        XCTAssertEqual(fixture.scheduler.permissionRequests, 0)
    }

    func testFirstLoadSelectsCalendarsAndFiltersExpiredAndOutOfRangeEvents() async throws {
        let ongoing = event("ongoing", start: -100, end: 600)
        let upcoming = event("upcoming", start: 800)
        let fixture = try makeFixture(events: [event("expired", start: -1_000, end: -100),
            event("future", start: 8 * 86_400), upcoming, ongoing, upcoming])
        defer { fixture.clean() }
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.selectedCalendarIDs, ["apple"])
        XCTAssertEqual(fixture.model.events.map(\.id), ["ongoing", "upcoming"])
        XCTAssertFalse(fixture.model.isLoading)
    }

    func testExplicitEmptySelectionPersistsAcrossModelRecreation() async throws {
        let fixture = try makeFixture(events: [event("one", start: 1_000)])
        defer { fixture.clean() }
        await fixture.model.refresh()
        fixture.model.setCalendarSelected("apple", isSelected: false)
        fixture.model.stop()
        XCTAssertTrue(fixture.model.events.isEmpty)
        let restored = CalendarAgendaModel(defaults: fixture.defaults, service: fixture.service, scheduler: fixture.scheduler, now: { self.instant })
        await restored.refresh()
        XCTAssertTrue(restored.selectedCalendarIDs.isEmpty)
        XCTAssertTrue(restored.events.isEmpty)
        restored.stop()
    }

    func testExplicitCalendarKindOverridesMeetingInferenceAndPersists() async throws {
        let fixture = try makeFixture(events: [event("meeting", start: 1_000, kind: .meeting)])
        defer { fixture.clean() }
        await fixture.model.refresh()
        fixture.model.setKind(.course, for: "apple")
        fixture.model.stop()
        XCTAssertEqual(fixture.model.events.first?.kind, .course)
        let restored = CalendarAgendaModel(defaults: fixture.defaults, service: fixture.service, scheduler: fixture.scheduler, now: { self.instant })
        await restored.refresh()
        XCTAssertEqual(restored.kind(for: "apple"), .course)
        XCTAssertEqual(restored.events.first?.kind, .course)
        restored.stop()
    }

    func testRevocationClearsEventsNotificationsAndReminderPreference() async throws {
        let fixture = try makeFixture(events: [event("one", start: 1_000)], remindersEnabled: true)
        defer { fixture.clean() }
        await fixture.model.refresh()
        XCTAssertFalse(fixture.scheduler.reminders.isEmpty)
        await fixture.service.setStatus(.denied)
        await fixture.model.refresh()
        XCTAssertEqual(fixture.model.authorization, .denied)
        XCTAssertTrue(fixture.model.events.isEmpty)
        XCTAssertTrue(fixture.scheduler.reminders.isEmpty)
        XCTAssertFalse(fixture.model.remindersEnabled)
        XCTAssertFalse(fixture.defaults.bool(forKey: "agenda.remindersEnabled"))
    }

    func testNotificationDenialDoesNotEnableReminderPreference() async throws {
        let fixture = try makeFixture()
        defer { fixture.clean() }
        fixture.scheduler.allowed = false
        await fixture.model.setRemindersEnabled(true)
        XCTAssertFalse(fixture.model.remindersEnabled)
        XCTAssertTrue(fixture.model.errorMessage?.contains("通知权限") == true)
        XCTAssertEqual(fixture.scheduler.permissionRequests, 1)
    }

    func testStoredPreferenceNeverPromptsOnRefreshAndRevokedNotificationsDisableIt() async throws {
        let fixture = try makeFixture(events: [event("one", start: 1_000)], remindersEnabled: true)
        defer { fixture.clean() }
        fixture.scheduler.allowed = false
        await fixture.model.refresh()
        XCTAssertEqual(fixture.scheduler.permissionRequests, 0)
        XCTAssertFalse(fixture.model.remindersEnabled)
        XCTAssertTrue(fixture.model.errorMessage?.contains("通知权限") == true)
    }

    func testDueIslandReminderIsDeduplicatedAndZeroLeadIncludesJustStartedEvent() async throws {
        let fixture = try makeFixture(events: [event("started", start: -5, end: 3_600),
            event("old", start: -120, end: 3_600)], remindersEnabled: true, lead: 0)
        defer { fixture.clean() }
        var delivered: [String] = []
        fixture.model.onReminder = { delivered.append($0.id) }
        await fixture.model.refresh()
        await fixture.model.refresh()
        XCTAssertEqual(delivered, ["started"])
    }

    func testLeadMinutesAreBoundedAndPersisted() throws {
        let fixture = try makeFixture()
        defer { fixture.clean() }
        fixture.model.reminderMinutes = -100
        XCTAssertEqual(fixture.model.reminderMinutes, 0)
        XCTAssertEqual(fixture.defaults.integer(forKey: "agenda.reminderMinutes"), 0)
        fixture.model.reminderMinutes = 2_000
        XCTAssertEqual(fixture.model.reminderMinutes, 1_440)
        XCTAssertEqual(fixture.defaults.integer(forKey: "agenda.reminderMinutes"), 1_440)
    }

    func testDisableWinsOverPendingNotificationPermissionResponse() async throws {
        let fixture = try makeFixture()
        defer { fixture.clean() }
        fixture.scheduler.delayPermission = true
        let pending = Task { await fixture.model.setRemindersEnabled(true) }
        while fixture.scheduler.permissionContinuation == nil { await Task.yield() }
        await fixture.model.setRemindersEnabled(false)
        fixture.scheduler.permissionContinuation?.resume(returning: true)
        fixture.scheduler.permissionContinuation = nil
        await pending.value
        XCTAssertFalse(fixture.model.remindersEnabled)
        XCTAssertFalse(fixture.defaults.bool(forKey: "agenda.remindersEnabled"))
    }

    func testFetchFailureIsVisibleAndDoesNotLeaveLoadingStateStuck() async throws {
        let fixture = try makeFixture()
        defer { fixture.clean() }
        await fixture.service.setFailFetch()
        await fixture.model.refresh()
        XCTAssertTrue(fixture.model.errorMessage?.contains("无法刷新日历") == true)
        XCTAssertFalse(fixture.model.isLoading)
    }

    func testDisableInvalidatesRefreshWaitingForNotificationAuthorizationCheck() async throws {
        let fixture = try makeFixture(events: [event("one", start: 1_000)], remindersEnabled: true)
        defer { fixture.clean() }
        fixture.scheduler.delayAuthorizationCheck = true
        let pending = Task { await fixture.model.refresh() }
        while fixture.scheduler.authorizationContinuation == nil { await Task.yield() }
        await fixture.model.setRemindersEnabled(false)
        fixture.scheduler.authorizationContinuation?.resume(returning: true)
        fixture.scheduler.authorizationContinuation = nil
        await pending.value
        XCTAssertFalse(fixture.model.remindersEnabled)
        XCTAssertTrue(fixture.scheduler.reminders.isEmpty)
        XCTAssertEqual(fixture.scheduler.replaceCalls, 0)
    }

    private func event(_ id: String, start: TimeInterval, end: TimeInterval? = nil,
                       kind: AgendaEventKind = .event) -> AgendaEvent {
        AgendaEvent(id: id, title: id, startDate: instant.addingTimeInterval(start),
            endDate: instant.addingTimeInterval(end ?? start + 3_600), calendarID: "apple", kind: kind)
    }

    private func makeFixture(status: CalendarAuthorization = .authorized, events: [AgendaEvent] = [],
                             remindersEnabled: Bool = false, lead: Int = 10) throws -> Fixture {
        let suite = "CalendarAgendaModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(remindersEnabled, forKey: "agenda.remindersEnabled")
        defaults.set(lead, forKey: "agenda.reminderMinutes")
        let service = CalendarModelTestService(status: status, snapshot: .init(calendars: [calendar], events: events))
        let scheduler = CalendarModelTestScheduler()
        let model = CalendarAgendaModel(defaults: defaults, service: service, scheduler: scheduler, now: { self.instant })
        return Fixture(suite: suite, defaults: defaults, service: service, scheduler: scheduler, model: model)
    }

    @MainActor
    private struct Fixture {
        let suite: String
        let defaults: UserDefaults
        let service: CalendarModelTestService
        let scheduler: CalendarModelTestScheduler
        let model: CalendarAgendaModel
        func clean() { model.stop(); defaults.removePersistentDomain(forName: suite) }
    }
}

private actor CalendarModelTestService: AgendaCalendarService {
    private var status: CalendarAuthorization
    private let snapshot: AgendaStoreSnapshot
    private var requests = 0
    private var fetches = 0
    private var failFetch = false
    init(status: CalendarAuthorization, snapshot: AgendaStoreSnapshot) { self.status = status; self.snapshot = snapshot }
    func authorization() -> CalendarAuthorization { status }
    func requestAccess() -> Bool { requests += 1; status = .authorized; return true }
    func fetch(from start: Date, to end: Date) throws -> AgendaStoreSnapshot {
        fetches += 1
        if failFetch { throw NSError(domain: "CalendarTests", code: 1) }
        return snapshot
    }
    func setStatus(_ status: CalendarAuthorization) { self.status = status }
    func setFailFetch() { failFetch = true }
    func counts() -> (requests: Int, fetches: Int) { (requests, fetches) }
}

@MainActor
private final class CalendarModelTestScheduler: AgendaReminderScheduling {
    var allowed = true
    var reminders: [AgendaReminder] = []
    var permissionRequests = 0
    var delayPermission = false
    var permissionContinuation: CheckedContinuation<Bool, Never>?
    var delayAuthorizationCheck = false
    var authorizationContinuation: CheckedContinuation<Bool, Never>?
    var replaceCalls = 0
    func requestAuthorization() async -> Bool {
        permissionRequests += 1
        if delayPermission { return await withCheckedContinuation { permissionContinuation = $0 } }
        return allowed
    }
    func isAuthorized() async -> Bool {
        if delayAuthorizationCheck { return await withCheckedContinuation { authorizationContinuation = $0 } }
        return allowed
    }
    func replace(_ reminders: [AgendaReminder]) { replaceCalls += 1; self.reminders = reminders }
    func clear() { reminders = [] }
}
