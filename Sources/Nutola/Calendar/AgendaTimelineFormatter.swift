import Foundation

enum AgendaTimelineFormatter {
    struct Parts: Equatable {
        var dayNumber: String
        var month: String
        var weekday: String
    }

    static func parts(for date: Date, calendar: Calendar = .current) -> Parts {
        let day = calendar.component(.day, from: date)
        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.locale = .current
        monthFormatter.dateFormat = "MMMM"
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.calendar = calendar
        weekdayFormatter.locale = .current
        weekdayFormatter.dateFormat = "EEE"
        return Parts(
            dayNumber: String(day),
            month: monthFormatter.string(from: date),
            weekday: weekdayFormatter.string(from: date))
    }
}
