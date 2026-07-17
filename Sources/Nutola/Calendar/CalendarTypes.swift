import Foundation

struct CalendarColor: Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let gray = CalendarColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1)
}

enum ConferenceProvider: Equatable, Sendable {
    case zoom, meet, teams, webex, other
}

struct CalendarEventSummary: Sendable, Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var location: String?
    var attendees: [String]
    var conferenceURL: URL?
    var calendarID: String?
    var calendarTitle: String?
    var calendarColor: CalendarColor

    var isInProgress: Bool {
        let now = Date()
        return start <= now && now < end
    }

    func isPast(at now: Date = .now) -> Bool {
        end <= now
    }

    /// Stable row key — recurring events reuse `eventIdentifier`.
    var rowID: String { "\(id)-\(Int(start.timeIntervalSince1970))" }

    var conferenceProvider: ConferenceProvider? {
        guard let host = conferenceURL?.host?.lowercased() else { return nil }
        if host.contains("zoom") { return .zoom }
        if host.contains("meet.google") { return .meet }
        if host.contains("teams") { return .teams }
        if host.contains("webex") { return .webex }
        return .other
    }

    var joinLabel: String {
        switch conferenceProvider {
        case .zoom: "Join Zoom"
        case .meet: "Join Meet"
        case .teams: "Join Teams"
        case .webex: "Join Webex"
        case .other, .none: "Join call"
        }
    }

    /// True when the event is in progress or starts within the countdown window.
    func isWithinCountdownWindow(
        at now: Date = .now,
        hours: Double = AppSettings.upcomingCountdownHours
    ) -> Bool {
        if isInProgress { return true }
        let interval = start.timeIntervalSince(now)
        return interval > 0 && interval <= hours * 3600
    }

    /// Gap between two events — zero when overlapping, otherwise time between intervals.
    static func gap(between a: CalendarEventSummary, and b: CalendarEventSummary) -> TimeInterval {
        if a.end <= b.start { return b.start.timeIntervalSince(a.end) }
        if b.end <= a.start { return a.start.timeIntervalSince(b.end) }
        return 0
    }

    /// Show join when in the countdown window, or when clustered with another conference
    /// event that is (overlapping or less than `clusterGap` apart).
    func shouldShowJoinButton(
        among peers: [CalendarEventSummary],
        at now: Date = .now,
        clusterGap: TimeInterval = 3600,
        hours: Double = AppSettings.upcomingCountdownHours
    ) -> Bool {
        guard conferenceURL != nil else { return false }
        if isWithinCountdownWindow(at: now, hours: hours) { return true }
        return peers.contains { other in
            guard other.conferenceURL != nil, other.rowID != rowID else { return false }
            return other.isWithinCountdownWindow(at: now, hours: hours)
                && Self.gap(between: self, and: other) < clusterGap
        }
    }
}

struct CalendarAgendaDay: Sendable, Identifiable, Equatable {
    var id: String
    var date: Date
    var label: String
    var events: [CalendarEventSummary]

    static func label(for day: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let dayStart = calendar.startOfDay(for: day)
        if dayStart == today { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), dayStart == tomorrow {
            return "Tomorrow"
        }
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = .current
        f.dateFormat = "d MMMM EEE"
        return f.string(from: day)
    }

    static func dayID(for date: Date, calendar: Calendar = .current) -> String {
        let start = calendar.startOfDay(for: date)
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: start)
    }
}

struct MeetingDayGroup: Identifiable, Equatable {
    var id: String
    var label: String
    var meetings: [Meeting]
}
