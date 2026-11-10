import EventKit
import Foundation

/// The system owns account login and synchronization for both Apple and Google.
/// EventKit objects stay on this actor; the UI receives only Sendable values.
actor EventKitCalendarService: AgendaCalendarService {
    private let store = EKEventStore()
    private var lastAuthorization: CalendarAuthorization?

    func authorization() -> CalendarAuthorization {
        let status: CalendarAuthorization = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .authorized
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        default: .denied
        }
        let changed = lastAuthorization != nil && lastAuthorization != status
        lastAuthorization = status
        // EventKit may retain objects fetched before a permission change.
        // Drop those objects once per transition, including reauthorization.
        if changed { store.reset() }
        return status
    }

    func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    func fetch(from start: Date, to end: Date) throws -> AgendaStoreSnapshot {
        guard authorization() == .authorized else { return .init(calendars: [], events: []) }
        let calendars = store.calendars(for: .event)
        let values = calendars.map { calendar in
            AgendaCalendar(id: calendar.calendarIdentifier, title: calendar.title,
                           sourceTitle: calendar.source.title,
                           source: Self.source(for: calendar.source))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        guard !calendars.isEmpty else { return .init(calendars: values, events: []) }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let events = store.events(matching: predicate).compactMap { event -> AgendaEvent? in
            guard event.status != .canceled, let startDate = event.startDate, let endDate = event.endDate,
                  endDate > start, startDate < end else { return nil }
            // Recurring instances share an identifier; include the occurrence date.
            let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
            let meetingURL = Self.meetingURL(url: event.url, notes: event.notes)
            let calendarKind = AgendaEventKind.suggested(forCalendarTitle: event.calendar.title)
            let kind: AgendaEventKind = calendarKind == .event && (meetingURL != nil || event.attendees?.isEmpty == false)
                ? .meeting : calendarKind
            return AgendaEvent(id: "\(identifier):\(startDate.timeIntervalSince1970)",
                title: event.title?.isEmpty == false ? event.title : "未命名日程",
                startDate: startDate, endDate: endDate, isAllDay: event.isAllDay,
                location: event.location, calendarID: event.calendar.calendarIdentifier,
                kind: kind, meetingURL: meetingURL)
        }
        return .init(calendars: values, events: events)
    }

    private nonisolated static func source(for source: EKSource) -> AgendaCalendarSource {
        let title = source.title.lowercased()
        if title.contains("google") || title.contains("gmail") { return .google }
        if source.sourceType == .local || title.contains("icloud") || title.contains("apple") { return .apple }
        // CalDAV alone does not identify a provider. Keep custom domains labeled
        // by their actual system account instead of guessing that they are Google.
        return .other
    }

    nonisolated static func meetingURL(url: URL?, notes: String?) -> URL? {
        func isMeetingURL(_ url: URL) -> Bool {
            guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
            return ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com",
                    "facetime.apple.com", "meeting.tencent.com", "larksuite.com", "feishu.cn"].contains {
                host == $0 || host.hasSuffix("." + $0)
            }
        }
        if let url, isMeetingURL(url) { return url }
        guard let notes, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(notes.startIndex..<notes.endIndex, in: notes)
        return detector.matches(in: notes, range: range).compactMap(\.url).first(where: isMeetingURL)
    }
}
