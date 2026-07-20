import Foundation

enum MeetingDayGrouper {
    static func group(
        meetings: [Meeting],
        now: Date = .now,
        maxDays: Int? = 14,
        maxCount: Int? = 20,
        calendar: Calendar = .current
    ) -> [MeetingDayGroup] {
        var recent = meetings
        if let maxDays {
            let cutoff = calendar.date(byAdding: .day, value: -maxDays, to: now) ?? now
            recent = recent.filter { $0.displayTime >= cutoff }
        }
        if let maxCount {
            recent = Array(recent.prefix(maxCount))
        }

        var buckets: [String: [Meeting]] = [:]
        for meeting in recent {
            let id = CalendarAgendaDay.dayID(for: meeting.displayTime, calendar: calendar)
            buckets[id, default: []].append(meeting)
        }

        return buckets.keys.sorted(by: >).compactMap { id in
            guard let items = buckets[id], !items.isEmpty else { return nil }
            let day = calendar.startOfDay(for: items[0].displayTime)
            return MeetingDayGroup(
                id: id,
                label: dayLabel(for: day, now: now, calendar: calendar),
                meetings: items.sorted { $0.displayTime > $1.displayTime }
            )
        }
        .sorted { $0.id > $1.id }
    }

    private static func dayLabel(for day: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        let dayStart = calendar.startOfDay(for: day)
        if dayStart == today { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), dayStart == yesterday {
            return "Yesterday"
        }
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = .current
        f.dateFormat = "EEE, MMM d"
        return f.string(from: day)
    }
}
