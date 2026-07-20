import Foundation

/// A morning briefing summarizing yesterday's meetings: key decisions, action
/// items due, and today's agenda.
struct DailyDigest: Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let yesterdayMeetings: [Meeting]
    let todayAgenda: [CalendarEventSummary]
    let summary: String
    let actionItems: [ActionItem]

    init(
        id: UUID = UUID(),
        date: Date,
        yesterdayMeetings: [Meeting],
        todayAgenda: [CalendarEventSummary],
        summary: String,
        actionItems: [ActionItem]
    ) {
        self.id = id
        self.date = date
        self.yesterdayMeetings = yesterdayMeetings
        self.todayAgenda = todayAgenda
        self.summary = summary
        self.actionItems = actionItems
    }
}

/// Builds a `DailyDigest` for a given date by filtering yesterday's meetings,
/// extracting action items from their summaries, and formatting a text briefing.
final class DailyDigestGenerator {
    /// Calendar used for "previous calendar day" filtering. Defaults to the
    /// user's current calendar; injected for deterministic tests.
    let calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Build a digest for `date`: collect meetings whose `createdAt` falls in
    /// the previous calendar day, gather action items from each meeting's
    /// summary, and produce a text briefing.
    ///
    /// - Parameters:
    ///   - summaries: maps a meeting id to its summary markdown. Pass explicit
    ///     summaries in tests; production callers pass `MeetingStore.summary(for:)`.
    func generate(
        for date: Date,
        meetings: [Meeting],
        agenda: [CalendarEventSummary],
        summaries: [UUID: String] = [:]
    ) -> DailyDigest {
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: date))!
        let yesterdayEnd = calendar.startOfDay(for: date)

        let yesterdayMeetings = meetings
            .filter { $0.createdAt >= yesterdayStart && $0.createdAt < yesterdayEnd }
            .sorted { $0.createdAt < $1.createdAt }

        // Per-meeting open action items, preserving yesterday's meeting order
        // so the "(from Meeting N)" tags stay aligned with the meeting list.
        var perMeetingItems: [[ActionItem]] = []
        var flatItems: [ActionItem] = []
        for meeting in yesterdayMeetings {
            let summary = summaries[meeting.id] ?? ""
            let items = ActionItemParser.openItems(summary)
            perMeetingItems.append(items)
            flatItems.append(contentsOf: items)
        }

        let summary = renderDigest(
            date: date,
            yesterdayMeetings: yesterdayMeetings,
            perMeetingItems: perMeetingItems,
            agenda: agenda,
            flatActionItems: flatItems
        )

        return DailyDigest(
            date: date,
            yesterdayMeetings: yesterdayMeetings,
            todayAgenda: agenda,
            summary: summary,
            actionItems: flatItems
        )
    }

    /// Build a digest for today so far: collect meetings whose `createdAt`
    /// falls in today's calendar day up to `date`, gather action items, and
    /// produce a text briefing. Useful for mid-day check-ins.
    func generateToday(
        for date: Date,
        meetings: [Meeting],
        agenda: [CalendarEventSummary],
        summaries: [UUID: String] = [:]
    ) -> DailyDigest {
        let todayStart = calendar.startOfDay(for: date)
        let todayMeetings = meetings
            .filter { $0.createdAt >= todayStart && $0.createdAt < date }
            .sorted { $0.createdAt < $1.createdAt }

        var perMeetingItems: [[ActionItem]] = []
        var flatItems: [ActionItem] = []
        for meeting in todayMeetings {
            let summary = summaries[meeting.id] ?? ""
            let items = ActionItemParser.openItems(summary)
            perMeetingItems.append(items)
            flatItems.append(contentsOf: items)
        }

        let summary = renderTodayDigest(
            date: date,
            todayMeetings: todayMeetings,
            perMeetingItems: perMeetingItems,
            agenda: agenda,
            flatActionItems: flatItems
        )

        return DailyDigest(
            date: date,
            yesterdayMeetings: todayMeetings,
            todayAgenda: agenda,
            summary: summary,
            actionItems: flatItems
        )
    }

    private func renderTodayDigest(
        date: Date,
        todayMeetings: [Meeting],
        perMeetingItems: [[ActionItem]],
        agenda: [CalendarEventSummary],
        flatActionItems: [ActionItem]
    ) -> String {
        var lines: [String] = []

        if todayMeetings.isEmpty {
            lines.append("📋 Today's Digest")
            lines.append("")
            lines.append("No meetings recorded today yet")
        } else {
            lines.append("📋 Today's Digest (\(todayMeetings.count) meetings so far)")
            lines.append("")
            for (index, meeting) in todayMeetings.enumerated() {
                let count = index < perMeetingItems.count ? perMeetingItems[index].count : 0
                lines.append("Meeting \(index + 1): \(meeting.title) — \(count) action items")
            }
        }

        if !flatActionItems.isEmpty {
            lines.append("")
            lines.append("📌 Action Items:")
            var itemIndex = 0
            for (meetingIndex, items) in perMeetingItems.enumerated() {
                for _ in items {
                    let item = flatActionItems[itemIndex]
                    let owner = item.owner.map { " (\($0))" } ?? ""
                    lines.append("- [ ] \(item.text)\(owner) (from Meeting \(meetingIndex + 1))")
                    itemIndex += 1
                }
            }
        }

        // Upcoming events (agenda items after current time)
        let upcoming = agenda.filter { $0.start >= date }.sorted { $0.start < $1.start }
        if !upcoming.isEmpty {
            lines.append("")
            lines.append("📅 Upcoming Today:")
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "HH:mm"
            for event in upcoming {
                lines.append("- \(formatter.string(from: event.start)) \(event.title)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Format an existing digest as a morning briefing. Renders the stored
    /// summary text (already formatted at generation time); reformats from
    /// fields when the stored summary is empty.
    func formatDigest(_ digest: DailyDigest) -> String {
        guard !digest.summary.isEmpty else {
            return renderDigest(
                date: digest.date,
                yesterdayMeetings: digest.yesterdayMeetings,
                perMeetingItems: Array(repeating: [], count: digest.yesterdayMeetings.count),
                agenda: digest.todayAgenda,
                flatActionItems: digest.actionItems
            )
        }
        return digest.summary
    }

    /// Internal formatter shared by `generate` and the empty-summary fallback
    /// in `formatDigest(_:)`.
    private func renderDigest(
        date: Date,
        yesterdayMeetings: [Meeting],
        perMeetingItems: [[ActionItem]],
        agenda: [CalendarEventSummary],
        flatActionItems: [ActionItem]
    ) -> String {
        var lines: [String] = []

        if yesterdayMeetings.isEmpty {
            lines.append("📋 Yesterday's Digest")
            lines.append("")
            lines.append("No meetings yesterday")
        } else {
            lines.append("📋 Yesterday's Digest (\(yesterdayMeetings.count) meetings)")
            lines.append("")
            for (index, meeting) in yesterdayMeetings.enumerated() {
                let count = index < perMeetingItems.count ? perMeetingItems[index].count : 0
                lines.append("Meeting \(index + 1): \(meeting.title) — \(count) action items")
            }
        }

        if !flatActionItems.isEmpty {
            lines.append("")
            lines.append("📌 Action Items Due:")
            // Track which meeting each item came from for the "(from Meeting N)" tag.
            var itemIndex = 0
            for (meetingIndex, items) in perMeetingItems.enumerated() {
                for _ in items {
                    let item = flatActionItems[itemIndex]
                    let owner = item.owner.map { " (\($0))" } ?? ""
                    lines.append("- [ ] \(item.text)\(owner) (from Meeting \(meetingIndex + 1))")
                    itemIndex += 1
                }
            }
        }

        if !agenda.isEmpty {
            lines.append("")
            lines.append("📅 Today's Agenda:")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
            for event in agenda.sorted(by: { $0.start < $1.start }) {
                lines.append("- \(formatter.string(from: event.start)) \(event.title)")
            }
        }

        return lines.joined(separator: "\n")
    }
}
