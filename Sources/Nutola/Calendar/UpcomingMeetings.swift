import Foundation

struct UpcomingMeetingsDay: Identifiable, Equatable {
    var id: String
    var label: String
    var events: [CalendarEventSummary]
}

enum UpcomingMeetings {
    static let defaultLimit = 7
    static let timelinePageDays = 3

    /// Days in the visible timeline window, dropping empty days except today.
    static func timelineDays(
        from agenda: [CalendarAgendaDay],
        offsetDays: Int = 0,
        pageDays: Int = timelinePageDays,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [CalendarAgendaDay] {
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: offsetDays, to: today),
              let windowEnd = calendar.date(byAdding: .day, value: pageDays - 1, to: windowStart)
        else { return [] }

        let todayStart = calendar.startOfDay(for: now)
        return agenda.compactMap { day in
            let dayStart = calendar.startOfDay(for: day.date)
            guard dayStart >= windowStart, dayStart <= windowEnd else { return nil }

            let upcoming = day.events
                .filter { !$0.isPast(at: now) }
                .sorted { $0.start < $1.start }
            if upcoming.isEmpty {
                if offsetDays == 0, dayStart == todayStart {
                    return CalendarAgendaDay(id: day.id, date: day.date, label: day.label, events: [])
                }
                return nil
            }
            return CalendarAgendaDay(id: day.id, date: day.date, label: day.label, events: upcoming)
        }
    }

    /// Next `limit` meetings that haven't ended yet, grouped by local day.
    static func grouped(
        from agenda: [CalendarAgendaDay],
        now: Date = .now,
        limit: Int = defaultLimit,
        calendar: Calendar = .current
    ) -> [UpcomingMeetingsDay] {
        let upcoming = agenda.flatMap(\.events)
            .filter { !$0.isPast(at: now) }
            .sorted { $0.start < $1.start }
            .prefix(limit)

        var days: [UpcomingMeetingsDay] = []
        for event in upcoming {
            let dayID = CalendarAgendaDay.dayID(for: event.start, calendar: calendar)
            if var last = days.last, last.id == dayID {
                last.events.append(event)
                days[days.count - 1] = last
            } else {
                let dayStart = calendar.startOfDay(for: event.start)
                days.append(UpcomingMeetingsDay(
                    id: dayID,
                    label: CalendarAgendaDay.label(for: dayStart, now: now, calendar: calendar),
                    events: [event]))
            }
        }
        return days
    }

    static func flat(from days: [UpcomingMeetingsDay]) -> [CalendarEventSummary] {
        days.flatMap(\.events)
    }
}
