import Foundation

/// Weekly meeting statistics for the Insights dashboard.
///
/// All time fields are in seconds (matching `Meeting.duration`); the per-day
/// `totalMinutes` is in whole minutes so the breakdown reads naturally in the UI.
struct MeetingInsights: Equatable {
    let totalMeetingTime: TimeInterval
    let meetingCount: Int
    let longestMeetingDuration: TimeInterval
    let longestMeetingTitle: String
    let busiestDay: String
    let busiestDayMeetingCount: Int
    let avgMeetingDuration: TimeInterval
    let perDayBreakdown: [(day: String, count: Int, totalMinutes: Int)]

    /// Tuples don't conform to `Equatable`, so synthesis can't cover
    /// `perDayBreakdown`. Compare the scalar fields directly and zip the
    /// breakdown entry-by-entry instead.
    static func == (lhs: MeetingInsights, rhs: MeetingInsights) -> Bool {
        lhs.totalMeetingTime == rhs.totalMeetingTime
            && lhs.meetingCount == rhs.meetingCount
            && lhs.longestMeetingDuration == rhs.longestMeetingDuration
            && lhs.longestMeetingTitle == rhs.longestMeetingTitle
            && lhs.busiestDay == rhs.busiestDay
            && lhs.busiestDayMeetingCount == rhs.busiestDayMeetingCount
            && lhs.avgMeetingDuration == rhs.avgMeetingDuration
            && lhs.perDayBreakdown.count == rhs.perDayBreakdown.count
            && zip(lhs.perDayBreakdown, rhs.perDayBreakdown).allSatisfy { a, b in
                a.day == b.day && a.count == b.count && a.totalMinutes == b.totalMinutes
            }
    }
}

/// Computes a `MeetingInsights` snapshot for a 7-day window starting at the
/// given date's start-of-day.
///
/// `forWeekOf` pins the window: any meeting whose `createdAt` falls in
/// `[weekStart, weekStart + 7 days)` is counted. The per-day breakdown always
/// holds exactly 7 entries (one per day of the selected week, in order) so the
/// dashboard's bar chart keeps a stable rhythm even for empty weeks.
enum MeetingInsightsCalculator {
    static func calculate(
        meetings: [Meeting],
        forWeekOf date: Date,
        calendar: Calendar = .current
    ) -> MeetingInsights {
        let weekStart = calendar.startOfDay(for: date)

        // Build the 7-day skeleton in week order so the breakdown is always
        // exactly 7 entries, even when the week held no meetings.
        var breakdown: [(day: String, count: Int, totalMinutes: Int)] = []
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart) else { continue }
            breakdown.append((day: weekdayLabel(for: day, calendar: calendar), count: 0, totalMinutes: 0))
        }

        guard let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) else {
            return MeetingInsights(
                totalMeetingTime: 0,
                meetingCount: 0,
                longestMeetingDuration: 0,
                longestMeetingTitle: "",
                busiestDay: "",
                busiestDayMeetingCount: 0,
                avgMeetingDuration: 0,
                perDayBreakdown: breakdown)
        }

        let inWeek = meetings.filter { $0.createdAt >= weekStart && $0.createdAt < weekEnd }

        var counts = [Int](repeating: 0, count: 7)
        var minutes = [Int](repeating: 0, count: 7)
        for meeting in inWeek {
            let dayStart = calendar.startOfDay(for: meeting.createdAt)
            let offset = calendar.dateComponents([.day], from: weekStart, to: dayStart).day ?? 0
            guard offset >= 0 && offset < 7 else { continue }
            counts[offset] += 1
            minutes[offset] += Int((meeting.duration / 60).rounded())
        }
        for i in 0..<min(breakdown.count, 7) {
            breakdown[i].count = counts[i]
            breakdown[i].totalMinutes = minutes[i]
        }

        let totalCount = inWeek.count
        let totalTime = inWeek.reduce(0.0) { $0 + $1.duration }
        let longest = inWeek.max { $0.duration < $1.duration }
        let avg = totalCount > 0 ? totalTime / Double(totalCount) : 0

        // Busiest day = the weekday with the most meetings. Strict `>` tie-break
        // keeps the earliest day in the week so the result is deterministic.
        var busiestDay = ""
        var busiestCount = 0
        for (i, c) in counts.enumerated() where breakdown.indices.contains(i) {
            if c > busiestCount {
                busiestCount = c
                busiestDay = breakdown[i].day
            }
        }

        return MeetingInsights(
            totalMeetingTime: totalTime,
            meetingCount: totalCount,
            longestMeetingDuration: longest?.duration ?? 0,
            longestMeetingTitle: longest?.title ?? "",
            busiestDay: busiestCount > 0 ? busiestDay : "",
            busiestDayMeetingCount: busiestCount,
            avgMeetingDuration: avg,
            perDayBreakdown: breakdown)
    }

    /// Short weekday symbol ("Mon", "Tue", …) for `date`, driven by the
    /// calendar's locale so tests can pin a deterministic locale.
    private static func weekdayLabel(for date: Date, calendar: Calendar) -> String {
        // `shortWeekdaySymbols` is [Sun, Mon, …, Sat]; `weekday` is 1…7 (1=Sunday).
        let weekday = calendar.component(.weekday, from: date)
        let symbols = calendar.shortWeekdaySymbols
        guard symbols.indices.contains(weekday - 1) else { return "" }
        return symbols[weekday - 1]
    }
}
