import EventKit
import Foundation

enum CalendarEventSelector {
    /// Picks the calendar event most likely in progress at `now`.
    static func select(
        from events: [EKEvent],
        at now: Date = .now,
        sourceApp: String? = nil
    ) -> EKEvent? {
        let inProgress = events.filter { event in
            guard !event.isAllDay,
                  let start = event.startDate, let end = event.endDate else { return false }
            return start <= now && now < end
        }
        guard !inProgress.isEmpty else { return nil }

        if let sourceApp, !sourceApp.isEmpty {
            let urlMatched = inProgress.filter {
                ConferenceURLParser.hostMatchesApp(ConferenceURLParser.parse(in: $0), sourceApp: sourceApp)
            }
            if let best = pickShortest(urlMatched, at: now) { return best }
        }

        return pickShortest(inProgress, at: now)
    }

    private static func pickShortest(_ events: [EKEvent], at now: Date) -> EKEvent? {
        events.max { lhs, rhs in
            let leftScore = score(lhs, at: now)
            let rightScore = score(rhs, at: now)
            if leftScore != rightScore { return leftScore < rightScore }
            return (lhs.startDate ?? .distantPast) < (rhs.startDate ?? .distantPast)
        }
    }

    /// Higher is better: prefer conference URLs, then shorter meetings, then later start.
    private static func score(_ event: EKEvent, at now: Date) -> Int {
        var s = 0
        if ConferenceURLParser.parse(in: event) != nil { s += 100 }
        if let start = event.startDate, let end = event.endDate {
            let duration = end.timeIntervalSince(start)
            if duration < 45 * 60 { s += 40 }
            else if duration < 90 * 60 { s += 20 }
            s += Int(min(start.timeIntervalSince(now) / 60, 30))
        }
        let title = (event.title ?? "").lowercased()
        if title.contains("hold") || title.contains("busy") || title.contains("focus") { s -= 50 }
        return s
    }
}
