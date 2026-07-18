import XCTest
@testable import Nutola

final class MeetingInsightsTests: XCTestCase {
    // Pin a deterministic Gregorian calendar with an en locale so weekday
    // labels and week boundaries don't depend on the test host's settings.
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        cal.locale = Locale(identifier: "en_US")
        calendar = cal
    }

    override func tearDown() {
        calendar = nil
        super.tearDown()
    }

    /// Week of Monday 2026-07-13 (a Monday) → the 7-day window runs Mon–Sun.
    private var weekStart: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: 9))!
    }

    private func makeMeeting(
        title: String,
        dayOffset: Int,
        hour: Int = 10,
        durationMinutes: Int = 30
    ) -> Meeting {
        var m = Meeting(
            title: title,
            createdAt: calendar.date(byAdding: .day, value: dayOffset, to: weekStart)!
                .addingTimeInterval(TimeInterval(hour * 3600)))
        m.duration = TimeInterval(durationMinutes * 60)
        m.state = .ready
        return m
    }

    // MARK: - totalMeetingTime

    func testTotalMeetingTime() {
        let meetings = [
            makeMeeting(title: "A", dayOffset: 0, durationMinutes: 60),
            makeMeeting(title: "B", dayOffset: 0, durationMinutes: 30),
            makeMeeting(title: "C", dayOffset: 1, durationMinutes: 45),
        ]
        let insights = MeetingInsightsCalculator.calculate(
            meetings: meetings, forWeekOf: weekStart, calendar: calendar)

        XCTAssertEqual(insights.totalMeetingTime, 135 * 60, accuracy: 0.001)
    }

    // MARK: - meetingCount

    func testMeetingCount() {
        let meetings = [
            makeMeeting(title: "A", dayOffset: 0),
            makeMeeting(title: "B", dayOffset: 1),
            makeMeeting(title: "C", dayOffset: 2),
            makeMeeting(title: "D", dayOffset: 3),
            makeMeeting(title: "E", dayOffset: 4),
        ]
        let insights = MeetingInsightsCalculator.calculate(
            meetings: meetings, forWeekOf: weekStart, calendar: calendar)

        XCTAssertEqual(insights.meetingCount, 5)
    }

    // MARK: - longestMeeting

    func testLongestMeeting() {
        let meetings = [
            makeMeeting(title: "Short", dayOffset: 0, durationMinutes: 15),
            makeMeeting(title: "Marathon", dayOffset: 2, durationMinutes: 60),
            makeMeeting(title: "Medium", dayOffset: 4, durationMinutes: 45),
        ]
        let insights = MeetingInsightsCalculator.calculate(
            meetings: meetings, forWeekOf: weekStart, calendar: calendar)

        XCTAssertEqual(insights.longestMeetingDuration, 60 * 60, accuracy: 0.001)
        XCTAssertEqual(insights.longestMeetingTitle, "Marathon")
    }

    // MARK: - busiestDay

    func testBusiestDay() {
        // Mon: 1 meeting, Wed: 3 meetings, Fri: 2 meetings.
        let meetings = [
            makeMeeting(title: "Mon A", dayOffset: 0),
            makeMeeting(title: "Wed A", dayOffset: 2),
            makeMeeting(title: "Wed B", dayOffset: 2),
            makeMeeting(title: "Wed C", dayOffset: 2),
            makeMeeting(title: "Fri A", dayOffset: 4),
            makeMeeting(title: "Fri B", dayOffset: 4),
        ]
        let insights = MeetingInsightsCalculator.calculate(
            meetings: meetings, forWeekOf: weekStart, calendar: calendar)

        XCTAssertEqual(insights.busiestDay, "Wed")
        XCTAssertEqual(insights.busiestDayMeetingCount, 3)
    }

    // MARK: - avgDuration

    func testAvgDuration() {
        let meetings = [
            makeMeeting(title: "A", dayOffset: 0, durationMinutes: 60),
            makeMeeting(title: "B", dayOffset: 1, durationMinutes: 30),
            makeMeeting(title: "C", dayOffset: 2, durationMinutes: 45),
        ]
        let insights = MeetingInsightsCalculator.calculate(
            meetings: meetings, forWeekOf: weekStart, calendar: calendar)

        XCTAssertEqual(insights.avgMeetingDuration, 45 * 60, accuracy: 0.001)
    }

    // MARK: - emptyWeek

    func testEmptyWeek() {
        let insights = MeetingInsightsCalculator.calculate(
            meetings: [], forWeekOf: weekStart, calendar: calendar)

        XCTAssertEqual(insights.totalMeetingTime, 0)
        XCTAssertEqual(insights.meetingCount, 0)
        XCTAssertEqual(insights.longestMeetingDuration, 0)
        XCTAssertEqual(insights.longestMeetingTitle, "")
        XCTAssertEqual(insights.busiestDay, "")
        XCTAssertEqual(insights.busiestDayMeetingCount, 0)
        XCTAssertEqual(insights.avgMeetingDuration, 0)
        XCTAssertEqual(insights.perDayBreakdown.count, 7)
        XCTAssertTrue(insights.perDayBreakdown.allSatisfy { $0.count == 0 && $0.totalMinutes == 0 })
    }

    // MARK: - perDayBreakdown

    func testPerDayBreakdown() {
        let meetings = [
            makeMeeting(title: "Mon", dayOffset: 0),
            makeMeeting(title: "Wed", dayOffset: 2),
            makeMeeting(title: "Fri", dayOffset: 4),
        ]
        let insights = MeetingInsightsCalculator.calculate(
            meetings: meetings, forWeekOf: weekStart, calendar: calendar)

        XCTAssertEqual(insights.perDayBreakdown.count, 7)
        // Monday 2026-07-13 is a Monday, so the week reads Mon, Tue, Wed, Thu, Fri, Sat, Sun.
        let days = insights.perDayBreakdown.map(\.day)
        XCTAssertEqual(days, ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
        XCTAssertEqual(insights.perDayBreakdown[0].count, 1)
        XCTAssertEqual(insights.perDayBreakdown[2].count, 1)
        XCTAssertEqual(insights.perDayBreakdown[4].count, 1)
        // The empty days still show up, just with zero meetings.
        XCTAssertEqual(insights.perDayBreakdown[1].count, 0)
        XCTAssertEqual(insights.perDayBreakdown[3].count, 0)
        XCTAssertEqual(insights.perDayBreakdown[5].count, 0)
        XCTAssertEqual(insights.perDayBreakdown[6].count, 0)
    }

    // MARK: - perDayBreakdown minutes

    func testPerDayBreakdownMinutes() {
        let meetings = [
            makeMeeting(title: "Mon", dayOffset: 0, durationMinutes: 60),
            makeMeeting(title: "Mon2", dayOffset: 0, durationMinutes: 30),
            makeMeeting(title: "Wed", dayOffset: 2, durationMinutes: 45),
        ]
        let insights = MeetingInsightsCalculator.calculate(
            meetings: meetings, forWeekOf: weekStart, calendar: calendar)

        XCTAssertEqual(insights.perDayBreakdown[0].totalMinutes, 90)
        XCTAssertEqual(insights.perDayBreakdown[2].totalMinutes, 45)
        XCTAssertEqual(insights.perDayBreakdown[1].totalMinutes, 0)
    }

    // MARK: - out-of-week meetings are excluded

    func testOutOfWeekMeetingsExcluded() {
        // The day before the week starts and the day it ends are both out.
        let before = makeMeeting(title: "Before", dayOffset: -1)
        let after = makeMeeting(title: "After", dayOffset: 7)
        let inWeek = makeMeeting(title: "In", dayOffset: 0)

        let insights = MeetingInsightsCalculator.calculate(
            meetings: [before, after, inWeek], forWeekOf: weekStart, calendar: calendar)

        XCTAssertEqual(insights.meetingCount, 1)
        XCTAssertEqual(insights.totalMeetingTime, 30 * 60, accuracy: 0.001)
        XCTAssertEqual(insights.longestMeetingTitle, "In")
    }

    // MARK: - longest tie-break is deterministic

    func testLongestMeetingTieKeepsFirstSeen() {
        // Two meetings with equal max duration: `max(by:)` keeps the first, so
        // the earliest one in the week wins the title.
        let meetings = [
            makeMeeting(title: "Later", dayOffset: 3, durationMinutes: 60),
            makeMeeting(title: "Earlier", dayOffset: 0, durationMinutes: 60),
        ]
        let insights = MeetingInsightsCalculator.calculate(
            meetings: meetings, forWeekOf: weekStart, calendar: calendar)

        XCTAssertEqual(insights.longestMeetingDuration, 60 * 60, accuracy: 0.001)
        XCTAssertEqual(insights.longestMeetingTitle, "Later")
    }
}
