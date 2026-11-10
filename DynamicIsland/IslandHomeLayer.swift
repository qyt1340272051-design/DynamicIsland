import Foundation

/// The music surface owns four cyclic home layers. Visiting the tray or tools
/// preserves the selected layer until the next expansion applies its default.
public nonisolated enum IslandHomeLayer: String, CaseIterable, Identifiable, Sendable {
    case music, calendar, courses, meetings

    public var id: Self { self }

    public var title: String {
        switch self {
        case .music: "音乐"
        case .calendar: "日历"
        case .courses: "课程"
        case .meetings: "会议"
        }
    }

    var agendaFilter: AgendaEventKind? {
        switch self {
        case .courses: .course
        case .meetings: .meeting
        case .music, .calendar: nil
        }
    }

    var index: Int { Self.allCases.firstIndex(of: self)! }

    func stepped(by offset: Int) -> Self {
        let layers = Self.allCases
        // Reduce before adding so even Int.min / Int.max offsets cannot
        // overflow, then normalize Swift's negative remainder.
        let destination = (index + offset % layers.count + layers.count) % layers.count
        return layers[destination]
    }
}
