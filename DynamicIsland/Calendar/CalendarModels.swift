import Foundation

public nonisolated enum CalendarAuthorization: String, Sendable {
    case notDetermined, authorized, denied, restricted
}

public nonisolated enum AgendaEventKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case event, course, meeting

    public var id: Self { self }
    public var title: String {
        switch self {
        case .event: "日历"
        case .course: "课程"
        case .meeting: "会议"
        }
    }
    public var systemImage: String {
        switch self {
        case .event: "calendar"
        case .course: "book.closed"
        case .meeting: "person.2"
        }
    }

    public static func suggested(forCalendarTitle title: String) -> Self {
        let title = title.lowercased()
        if ["课程", "课表", "上课", "course", "class", "lecture"].contains(where: title.contains) { return .course }
        if ["会议", "meeting", "conference"].contains(where: title.contains) { return .meeting }
        return .event
    }
}

public nonisolated enum AgendaCalendarSource: String, Sendable {
    case apple, google, other

    public var title: String {
        switch self {
        case .apple: "Apple 日历"
        case .google: "Google 日历"
        case .other: "系统日历账户"
        }
    }
}

public nonisolated struct AgendaCalendar: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let sourceTitle: String
    public let source: AgendaCalendarSource

    public init(id: String, title: String, sourceTitle: String, source: AgendaCalendarSource) {
        self.id = id
        self.title = title
        self.sourceTitle = sourceTitle
        self.source = source
    }
}

public nonisolated struct AgendaEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let isAllDay: Bool
    public let location: String?
    public let calendarID: String
    public var kind: AgendaEventKind
    public let meetingURL: URL?

    public init(id: String, title: String, startDate: Date, endDate: Date,
                isAllDay: Bool = false, location: String? = nil, calendarID: String,
                kind: AgendaEventKind = .event, meetingURL: URL? = nil) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.calendarID = calendarID
        self.kind = kind
        self.meetingURL = meetingURL
    }
}

nonisolated struct AgendaStoreSnapshot: Sendable {
    var calendars: [AgendaCalendar]
    var events: [AgendaEvent]
}

protocol AgendaCalendarService: Sendable {
    func authorization() async -> CalendarAuthorization
    func requestAccess() async throws -> Bool
    func fetch(from start: Date, to end: Date) async throws -> AgendaStoreSnapshot
}
