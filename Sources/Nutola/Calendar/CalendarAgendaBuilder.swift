import CoreGraphics
import EventKit
import Foundation

enum CalendarAgendaBuilder {
    static func map(_ event: EKEvent) -> CalendarEventSummary? {
        guard !event.isAllDay,
              let start = event.startDate, let end = event.endDate,
              let id = event.eventIdentifier else { return nil }
        return CalendarEventSummary(
            id: id,
            title: event.title?.isEmpty == false ? event.title! : "Untitled event",
            start: start,
            end: end,
            location: event.location?.isEmpty == false ? event.location : nil,
            attendees: AttendeeExtractor.names(from: event),
            conferenceURL: ConferenceURLParser.parse(in: event),
            calendarID: event.calendar.calendarIdentifier,
            calendarTitle: event.calendar.title,
            calendarColor: CalendarColor(cgColor: event.calendar.cgColor)
        )
    }

    static func buildAgenda(
        from events: [EKEvent],
        now: Date = .now,
        offsetDays: Int = 0,
        horizonDays: Int = 3,
        calendar: Calendar = .current
    ) -> [CalendarAgendaDay] {
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: offsetDays, to: today),
              let windowEnd = calendar.date(byAdding: .day, value: horizonDays - 1, to: windowStart),
              let windowEndDay = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: windowEnd)
        else { return [] }

        let summaries = events
            .compactMap(map)
            .filter { $0.start >= windowStart && $0.start <= windowEndDay }
            .filter { event in
                guard !AppSettings.showEventsWithoutParticipants else { return true }
                return !event.attendees.isEmpty || event.conferenceURL != nil
            }
            .filter { event in
                // Hide archived events (by title series or individual event ID)
                !ArchivedEventStore().isArchived(title: event.title, eventID: event.id)
            }
            .sorted { $0.start < $1.start }

        var grouped: [String: [CalendarEventSummary]] = [:]
        for event in summaries {
            let dayID = CalendarAgendaDay.dayID(for: event.start, calendar: calendar)
            grouped[dayID, default: []].append(event)
        }

        var days: [CalendarAgendaDay] = []
        for offset in 0..<horizonDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: windowStart) else { continue }
            let id = CalendarAgendaDay.dayID(for: day, calendar: calendar)
            days.append(CalendarAgendaDay(
                id: id,
                date: day,
                label: CalendarAgendaDay.label(for: day, now: now, calendar: calendar),
                events: grouped[id] ?? []
            ))
        }
        return days
    }

    static func nextUpcoming(
        in agenda: [CalendarAgendaDay],
        now: Date = .now
    ) -> CalendarEventSummary? {
        agenda.flatMap(\.events)
            .filter { !$0.isPast(at: now) }
            .sorted { $0.start < $1.start }
            .first
    }
}
