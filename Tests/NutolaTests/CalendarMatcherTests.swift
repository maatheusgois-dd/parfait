import XCTest
@testable import Nutola

final class CalendarMatcherTests: XCTestCase {
    func testRelativeTimeWithinWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(52 * 60)
        XCTAssertEqual(RelativeTimeFormatter.until(start, now: now, within: 3), "in 52m")
    }

    func testRelativeTimeOutsideWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(4 * 3600)
        XCTAssertNil(RelativeTimeFormatter.until(start, now: now, within: 3))
    }

    func testRelativeTimeHoursAndMinutes() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(2 * 3600 + 15 * 60)
        XCTAssertEqual(RelativeTimeFormatter.until(start, now: now, within: 3), "in 2h 15m")
    }

    func testAgendaDayLabels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 14, hour: 12))!
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let later = calendar.date(byAdding: .day, value: 2, to: today)!

        XCTAssertEqual(CalendarAgendaDay.label(for: today, now: now, calendar: calendar), "Today")
        XCTAssertEqual(CalendarAgendaDay.label(for: tomorrow, now: now, calendar: calendar), "Tomorrow")
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMMM EEE"
        XCTAssertEqual(CalendarAgendaDay.label(for: later, now: now, calendar: calendar), f.string(from: later))
    }

    func testMeetingDayGrouperOrdersNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 14, hour: 18))!
        let todayMeeting = Meeting(
            title: "Today",
            createdAt: calendar.date(byAdding: .hour, value: -2, to: now)!)
        let yesterdayMeeting = Meeting(
            title: "Yesterday",
            createdAt: calendar.date(byAdding: .day, value: -1, to: now)!)

        let groups = MeetingDayGrouper.group(
            meetings: [yesterdayMeeting, todayMeeting],
            now: now,
            calendar: calendar)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].label, "Today")
        XCTAssertEqual(groups[0].meetings.first?.title, "Today")
        XCTAssertEqual(groups[1].label, "Yesterday")
    }

    func testConferenceURLParserFindsZoomLink() {
        let text = "Join https://zoom.us/j/123456789?pwd=abc for the call"
        let regex = try! NSRegularExpression(pattern: #"https?://[\w.-]*zoom\.us/[^\s<>"]+"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let match = regex.firstMatch(in: text, range: range)
        XCTAssertNotNil(match)
        XCTAssertTrue(ConferenceURLParser.hostMatchesApp(URL(string: "https://zoom.us/j/123"), sourceApp: "zoom.us"))
        XCTAssertFalse(ConferenceURLParser.hostMatchesApp(URL(string: "https://meet.google.com/abc"), sourceApp: "zoom.us"))
    }

    func testUpcomingMeetingsGroupsByDayAndSkipsPast() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 14, hour: 23, minute: 0))!

        let past = CalendarEventSummary(
            id: "past", title: "Past standup", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800),
            location: nil, attendees: [], conferenceURL: nil, calendarID: nil, calendarTitle: nil, calendarColor: .gray)
        let tonight = CalendarEventSummary(
            id: "tonight", title: "test metting", start: now.addingTimeInterval(24 * 60), end: now.addingTimeInterval(39 * 60),
            location: nil, attendees: [], conferenceURL: nil, calendarID: nil, calendarTitle: nil, calendarColor: .gray)
        let tomorrow = CalendarEventSummary(
            id: "tomorrow", title: "All Hands", start: now.addingTimeInterval(12 * 3600), end: now.addingTimeInterval(13 * 3600),
            location: nil, attendees: [], conferenceURL: nil, calendarID: nil, calendarTitle: nil, calendarColor: .gray)

        let agenda = [
            CalendarAgendaDay(id: "today", date: calendar.startOfDay(for: now), label: "Today", events: [past, tonight]),
            CalendarAgendaDay(
                id: "tomorrow",
                date: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!,
                label: "Tomorrow",
                events: [tomorrow]),
        ]

        let grouped = UpcomingMeetings.grouped(from: agenda, now: now, limit: 7, calendar: calendar)
        XCTAssertEqual(grouped.flatMap(\.events).map(\.title), ["test metting", "All Hands"])
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped[0].label, "Today")
        XCTAssertEqual(grouped[1].label, "Tomorrow")
    }

    func testTimelineDaysCapsAtThreeDaysWithAllEvents() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 10))!
        let today = calendar.startOfDay(for: now)

        func event(_ id: String, day: Date, hour: Int) -> CalendarEventSummary {
            let start = calendar.date(byAdding: .hour, value: hour, to: day)!
            return CalendarEventSummary(
                id: id, title: id, start: start, end: start.addingTimeInterval(1800),
                location: nil, attendees: [], conferenceURL: nil, calendarID: nil, calendarTitle: nil, calendarColor: .gray)
        }

        func day(_ offset: Int, events: [CalendarEventSummary]) -> CalendarAgendaDay {
            let date = calendar.date(byAdding: .day, value: offset, to: today)!
            return CalendarAgendaDay(
                id: "d\(offset)",
                date: date,
                label: "Day \(offset)",
                events: events)
        }

        let heavyDay = (0..<12).map { event("e\($0)", day: today, hour: 11 + $0) }
        let heavyPage = UpcomingMeetings.timelineDays(
            from: [day(0, events: heavyDay)],
            offsetDays: 0,
            pageDays: 3,
            now: now,
            calendar: calendar)
        XCTAssertEqual(heavyPage.count, 1)
        XCTAssertEqual(heavyPage[0].events.count, 12)

        let agenda = (0..<4).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: today)!
            return day(offset, events: [event("d\(offset)", day: date, hour: 14)])
        }
        let page = UpcomingMeetings.timelineDays(from: agenda, offsetDays: 0, pageDays: 3, now: now, calendar: calendar)
        XCTAssertEqual(page.map(\.id), ["d0", "d1", "d2"])
        XCTAssertEqual(page.flatMap(\.events).map(\.title), ["d0", "d1", "d2"])
    }

    func testTimelineDaysPagesWindowAndSkipsEmptyDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 10))!
        let today = calendar.startOfDay(for: now)
        let day1 = calendar.date(byAdding: .day, value: 1, to: today)!
        let day2 = calendar.date(byAdding: .day, value: 2, to: today)!
        let day4 = calendar.date(byAdding: .day, value: 4, to: today)!

        func event(_ id: String, day: Date, hour: Int) -> CalendarEventSummary {
            let start = calendar.date(byAdding: .hour, value: hour, to: day)!
            return CalendarEventSummary(
                id: id, title: id, start: start, end: start.addingTimeInterval(1800),
                location: nil, attendees: [], conferenceURL: nil, calendarID: nil, calendarTitle: nil, calendarColor: .gray)
        }

        let agenda = [
            CalendarAgendaDay(id: "d0", date: today, label: "Today", events: [event("today", day: today, hour: 14)]),
            CalendarAgendaDay(id: "d1", date: day1, label: "Tomorrow", events: [event("tomorrow", day: day1, hour: 12)]),
            CalendarAgendaDay(id: "d2", date: day2, label: "24 July Fri", events: []),
            CalendarAgendaDay(id: "d4", date: day4, label: "27 July Mon", events: [event("monday", day: day4, hour: 9)]),
        ]

        let firstPage = UpcomingMeetings.timelineDays(from: agenda, offsetDays: 0, pageDays: 3, now: now, calendar: calendar)
        XCTAssertEqual(firstPage.map(\.id), ["d0", "d1"])
        XCTAssertEqual(firstPage.flatMap(\.events).map(\.title), ["today", "tomorrow"])

        let secondPage = UpcomingMeetings.timelineDays(from: agenda, offsetDays: 3, pageDays: 3, now: now, calendar: calendar)
        XCTAssertEqual(secondPage.map(\.id), ["d4"])
        XCTAssertEqual(secondPage.flatMap(\.events).map(\.title), ["monday"])
    }

    func testTimelineShowsEmptyToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 18))!
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let past = CalendarEventSummary(
            id: "past", title: "Past", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800),
            location: nil, attendees: [], conferenceURL: nil, calendarID: nil, calendarTitle: nil, calendarColor: .gray)
        let tomorrowEvent = CalendarEventSummary(
            id: "future", title: "Tomorrow", start: tomorrow.addingTimeInterval(3600 * 10), end: tomorrow.addingTimeInterval(3600 * 11),
            location: nil, attendees: [], conferenceURL: nil, calendarID: nil, calendarTitle: nil, calendarColor: .gray)

        let agenda = [
            CalendarAgendaDay(id: "d0", date: today, label: "Today", events: [past]),
            CalendarAgendaDay(id: "d1", date: tomorrow, label: "Tomorrow", events: [tomorrowEvent]),
        ]

        let days = UpcomingMeetings.timelineDays(from: agenda, offsetDays: 0, pageDays: 2, now: now, calendar: calendar)
        XCTAssertEqual(days.count, 2)
        XCTAssertTrue(days[0].events.isEmpty)
        XCTAssertEqual(days[1].events.map(\.title), ["Tomorrow"])
    }

    func testAgendaTimelineFormatterParts() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 7, day: 24, hour: 12))!
        let parts = AgendaTimelineFormatter.parts(for: date, calendar: calendar)
        XCTAssertEqual(parts.dayNumber, "24")
        XCTAssertEqual(parts.month, "July")
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.calendar = calendar
        weekdayFormatter.locale = .current
        weekdayFormatter.dateFormat = "EEE"
        XCTAssertEqual(parts.weekday, weekdayFormatter.string(from: date))
    }

    func testConferenceDeeplinkZoom() {
        let web = URL(string: "https://zoom.us/j/123456789?pwd=abc")!
        let deeplink = ConferenceJoiner.deeplinkURL(for: web)!
        XCTAssertEqual(deeplink.scheme, "zoommtg")
        XCTAssertEqual(deeplink.host, "zoom.us")
        XCTAssertEqual(deeplink.path, "/join")
        let query = URLComponents(url: deeplink, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "confno" }?.value, "123456789")
        XCTAssertEqual(query.first { $0.name == "pwd" }?.value, "abc")
        XCTAssertEqual(query.first { $0.name == "action" }?.value, "join")
    }

    func testConferenceDeeplinkTeams() {
        let web = URL(string: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc")!
        let deeplink = ConferenceJoiner.deeplinkURL(for: web)!
        XCTAssertEqual(deeplink.scheme, "msteams")
        XCTAssertEqual(deeplink.host, "teams.microsoft.com")
    }

    func testConferenceJoinLabelAndWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let zoom = CalendarEventSummary(
            id: "zoom", title: "test metting",
            start: now.addingTimeInterval(24 * 60), end: now.addingTimeInterval(39 * 60),
            location: nil, attendees: [],
            conferenceURL: URL(string: "https://zoom.us/j/123"),
            calendarID: nil, calendarTitle: nil, calendarColor: .gray)
        XCTAssertEqual(zoom.joinLabel, "Join Zoom")
        XCTAssertTrue(zoom.isWithinCountdownWindow(at: now, hours: 3))
        let far = CalendarEventSummary(
            id: "far", title: "Later",
            start: now.addingTimeInterval(4 * 3600), end: now.addingTimeInterval(5 * 3600),
            location: nil, attendees: [],
            conferenceURL: URL(string: "https://zoom.us/j/456"),
            calendarID: nil, calendarTitle: nil, calendarColor: .gray)
        XCTAssertFalse(far.isWithinCountdownWindow(at: now, hours: 3))

        let meet = CalendarEventSummary(
            id: "meet", title: "Standup",
            start: now.addingTimeInterval(3600), end: now.addingTimeInterval(4500),
            location: nil, attendees: [],
            conferenceURL: URL(string: "https://meet.google.com/abc-defg-hij"),
            calendarID: nil, calendarTitle: nil, calendarColor: .gray)
        XCTAssertEqual(meet.joinLabel, "Join Meet")
    }

    func testShouldShowJoinButtonForClusteredMeetings() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let zoomURL = URL(string: "https://zoom.us/j/123")!
        let allHands = CalendarEventSummary(
            id: "all-hands", title: "All Hands",
            start: now.addingTimeInterval(9 * 3600 + 4 * 60),
            end: now.addingTimeInterval(9 * 3600 + 44 * 60),
            location: zoomURL.absoluteString, attendees: [],
            conferenceURL: zoomURL,
            calendarID: nil, calendarTitle: nil, calendarColor: .gray)
        let followUp = CalendarEventSummary(
            id: "follow-up", title: "Follow Up",
            start: now.addingTimeInterval(10 * 3600 + 34 * 60),
            end: now.addingTimeInterval(11 * 3600 + 34 * 60),
            location: zoomURL.absoluteString, attendees: [],
            conferenceURL: zoomURL,
            calendarID: nil, calendarTitle: nil, calendarColor: .gray)
        let peers = [allHands, followUp]

        XCTAssertEqual(CalendarEventSummary.gap(between: allHands, and: followUp), 50 * 60)
        XCTAssertTrue(allHands.shouldShowJoinButton(among: peers, at: now, hours: 10))
        XCTAssertTrue(followUp.shouldShowJoinButton(among: peers, at: now, hours: 10))

        let far = CalendarEventSummary(
            id: "far", title: "Later",
            start: now.addingTimeInterval(12 * 3600), end: now.addingTimeInterval(13 * 3600),
            location: zoomURL.absoluteString, attendees: [],
            conferenceURL: zoomURL,
            calendarID: nil, calendarTitle: nil, calendarColor: .gray)
        XCTAssertFalse(far.shouldShowJoinButton(among: [allHands, far], at: now, hours: 3))
    }

    func testStartsInFormatter() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(24 * 60)
        XCTAssertEqual(RelativeTimeFormatter.startsIn(start, now: now), "in 24m")
    }

    func testEndsInFormatter() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let end = now.addingTimeInterval(14 * 60)
        XCTAssertEqual(RelativeTimeFormatter.endsIn(end, now: now), "in 14m")
    }

    func testLeftFormatter() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let end = now.addingTimeInterval(13 * 60)
        XCTAssertEqual(RelativeTimeFormatter.left(until: end, now: now), "13m left")
    }

    func testCalendarSelectionPersistence() {
        AppSettings.resetCalendarSelection()
        XCTAssertTrue(AppSettings.isCalendarEnabled(id: "work"))
        AppSettings.setCalendarEnabled(id: "work", enabled: false)
        XCTAssertFalse(AppSettings.isCalendarEnabled(id: "work"))
        AppSettings.setCalendarEnabled(id: "work", enabled: true)
        XCTAssertTrue(AppSettings.isCalendarEnabled(id: "work"))
        AppSettings.resetCalendarSelection()
        XCTAssertTrue(AppSettings.disabledCalendarIDs.isEmpty)
    }
}
