import XCTest
@testable import Nutola

final class TokenUsageTrackerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var tracker: TokenUsageTracker!

    override func setUp() {
        super.setUp()
        suiteName = "nutola-token-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        tracker = TokenUsageTracker(defaults: defaults, key: "token-usage-history")
    }

    override func tearDown() {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        tracker = nil
        super.tearDown()
    }

    // MARK: - record

    func testRecordAddsToToday() {
        tracker.record(promptTokens: 100, completionTokens: 50)
        let days = tracker.last14Days()
        XCTAssertEqual(days.count, 14)
        let today = days.last!
        XCTAssertEqual(today.promptTokens, 100)
        XCTAssertEqual(today.completionTokens, 50)
        XCTAssertEqual(today.totalTokens, 150)
    }

    func testMultipleRecordsSameDayAccumulate() {
        tracker.record(promptTokens: 100, completionTokens: 50)
        tracker.record(promptTokens: 200, completionTokens: 10)
        tracker.record(promptTokens: 1, completionTokens: 0)
        let today = tracker.last14Days().last!
        XCTAssertEqual(today.promptTokens, 301)
        XCTAssertEqual(today.completionTokens, 60)
        XCTAssertEqual(today.totalTokens, 361)
    }

    // MARK: - last14Days

    func testLast14DaysFillsMissingDays() {
        // Only today has data; the window must still be 14 entries.
        tracker.record(promptTokens: 10, completionTokens: 5)
        let days = tracker.last14Days()
        XCTAssertEqual(days.count, 14)
        // The first 13 are zero-filled placeholders.
        for day in days.dropLast() {
            XCTAssertEqual(day.totalTokens, 0)
        }
        // Today holds the only data.
        XCTAssertEqual(days.last!.totalTokens, 15)
    }

    func testLast14DaysIsOldestFirst() {
        tracker.record(promptTokens: 1, completionTokens: 1)
        let days = tracker.last14Days()
        for i in 0..<days.count - 1 {
            XCTAssertLessThan(days[i].date, days[i + 1].date, "days must be ascending")
        }
    }

    // MARK: - totalForLast14Days

    func testTotalForLast14Days() {
        tracker.record(promptTokens: 100, completionTokens: 50)
        tracker.record(promptTokens: 200, completionTokens: 100)
        XCTAssertEqual(tracker.totalForLast14Days(), 450)
    }

    func testTotalForLast14DaysEmptyIsZero() {
        XCTAssertEqual(tracker.totalForLast14Days(), 0)
    }

    // MARK: - clear

    func testClearEmptiesHistory() {
        tracker.record(promptTokens: 100, completionTokens: 50)
        XCTAssertEqual(tracker.totalForLast14Days(), 150)
        tracker.clear()
        XCTAssertEqual(tracker.totalForLast14Days(), 0)
        // After clear, last14Days still returns 14 zero-filled rows.
        let days = tracker.last14Days()
        XCTAssertEqual(days.count, 14)
        for day in days {
            XCTAssertEqual(day.totalTokens, 0)
        }
    }

    // MARK: - isolation

    func testIsolationWithTestDefaults() {
        // Writing to the test suite must not leak into standard defaults.
        let standardTracker = TokenUsageTracker()
        let standardBefore = standardTracker.totalForLast14Days()
        tracker.record(promptTokens: 999_999, completionTokens: 999_999)
        XCTAssertEqual(standardTracker.totalForLast14Days(), standardBefore,
                       "test tracker must not write to UserDefaults.standard")
    }

    // MARK: - DailyTokenUsage

    func testDailyTokenUsageTotalAndId() {
        let entry = DailyTokenUsage(date: "2026-07-17", promptTokens: 1234, completionTokens: 567)
        XCTAssertEqual(entry.id, "2026-07-17")
        XCTAssertEqual(entry.totalTokens, 1801)
    }
}
