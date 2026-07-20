import Foundation

/// Estimated cost of a meeting: attendee count × duration × hourly rate.
///
/// Nutola has no payroll data, so the cost is a rough "what is everyone's time
/// worth" estimate based on a single configurable hourly rate applied to every
/// attendee. The rate defaults to $100/hr (see `AppSettings.hourlyRatePerPerson`)
/// and the badge can be hidden entirely via `AppSettings.showMeetingCost`.
struct MeetingCost: Equatable, Sendable {
    let attendeeCount: Int
    let durationMinutes: Int
    let hourlyRatePerPerson: Double
    let totalCost: Double
    let formattedCost: String

    /// Renders `totalCost` as a currency string (e.g. "$1,234") using
    /// `NumberFormatter` currency style pinned to `en_US`. The badge is a rough
    /// estimate, not a payroll figure, so we always show the `$` symbol with a
    /// comma thousands separator regardless of the user's system locale — a
    /// "💰 R$ 1.234" badge on a pt-BR machine would be more confusing than a
    /// consistent "$1,234". Zero fraction digits keep short meetings readable.
    static func format(_ cost: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: cost)) ?? "$\(Int(cost))"
    }
}

/// Computes `MeetingCost` estimates for a meeting. Pure functions, no state —
/// the hourly rate is supplied by the caller (typically from `AppSettings`)
/// so the calculator stays trivially testable.
enum MeetingCostCalculator {
    /// Estimate the cost of a meeting given explicit attendee count, duration
    /// (in minutes), and a per-person hourly rate.
    ///
    /// `totalCost = attendeeCount × (durationMinutes / 60) × hourlyRatePerPerson`.
    /// Zero attendees or zero duration both yield a $0 cost, and the formatted
    /// string reflects that (e.g. "$0") rather than hiding the badge — the UI
    /// decides visibility via `attendeeCount > 0 && durationMinutes > 0`.
    static func calculate(
        attendeeCount: Int,
        durationMinutes: Int,
        hourlyRatePerPerson: Double
    ) -> MeetingCost {
        let clampedAttendees = max(0, attendeeCount)
        let clampedMinutes = max(0, durationMinutes)
        let clampedRate = max(0, hourlyRatePerPerson)
        let total = Double(clampedAttendees)
            * (Double(clampedMinutes) / 60.0)
            * clampedRate
        return MeetingCost(
            attendeeCount: clampedAttendees,
            durationMinutes: clampedMinutes,
            hourlyRatePerPerson: clampedRate,
            totalCost: total,
            formattedCost: MeetingCost.format(total))
    }

    /// Convenience: estimate from the meeting's attendee list and a `TimeInterval`
    /// duration (seconds), converting the duration to whole minutes for display.
    /// A 90-second call rounds to 2 minutes for the badge, matching how the
    /// duration chip elsewhere renders short meetings.
    static func estimate(
        attendees: [String],
        duration: TimeInterval,
        hourlyRatePerPerson: Double
    ) -> MeetingCost {
        let minutes = Int((duration / 60.0).rounded())
        return calculate(
            attendeeCount: attendees.count,
            durationMinutes: minutes,
            hourlyRatePerPerson: hourlyRatePerPerson)
    }
}
