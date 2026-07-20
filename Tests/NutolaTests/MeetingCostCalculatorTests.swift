import XCTest
@testable import Nutola

final class MeetingCostCalculatorTests: XCTestCase {

    // MARK: - calculate(attendeeCount:durationMinutes:hourlyRatePerPerson:)

    func testBasicCalculation() {
        // 3 attendees × 60 min × $100/hr = 3 × 1.0 × 100 = $300
        let cost = MeetingCostCalculator.calculate(
            attendeeCount: 3,
            durationMinutes: 60,
            hourlyRatePerPerson: 100.0)
        XCTAssertEqual(cost.attendeeCount, 3)
        XCTAssertEqual(cost.durationMinutes, 60)
        XCTAssertEqual(cost.hourlyRatePerPerson, 100.0)
        XCTAssertEqual(cost.totalCost, 300.0, accuracy: 0.001)
    }

    func testZeroAttendees() {
        // No attendees → $0 even with a rate and duration.
        let cost = MeetingCostCalculator.calculate(
            attendeeCount: 0,
            durationMinutes: 60,
            hourlyRatePerPerson: 100.0)
        XCTAssertEqual(cost.totalCost, 0.0, accuracy: 0.001)
        XCTAssertEqual(cost.attendeeCount, 0)
        XCTAssertEqual(cost.durationMinutes, 60)
        XCTAssertEqual(cost.hourlyRatePerPerson, 100.0)
    }

    func testZeroDuration() {
        // Zero-length meeting → $0 even with attendees and a rate.
        let cost = MeetingCostCalculator.calculate(
            attendeeCount: 5,
            durationMinutes: 0,
            hourlyRatePerPerson: 100.0)
        XCTAssertEqual(cost.totalCost, 0.0, accuracy: 0.001)
        XCTAssertEqual(cost.attendeeCount, 5)
        XCTAssertEqual(cost.durationMinutes, 0)
    }

    func testZeroRate() {
        // A $0 rate yields a $0 cost but keeps the attendee/duration fields intact.
        let cost = MeetingCostCalculator.calculate(
            attendeeCount: 4,
            durationMinutes: 30,
            hourlyRatePerPerson: 0.0)
        XCTAssertEqual(cost.totalCost, 0.0, accuracy: 0.001)
        XCTAssertEqual(cost.hourlyRatePerPerson, 0.0)
    }

    func testFormattedCost() {
        // $1,234.00 → "$1,234" (no fraction digits, currency style).
        let cost = MeetingCostCalculator.calculate(
            attendeeCount: 6,
            durationMinutes: 60,
            hourlyRatePerPerson: 205.666667)
        // 6 × 1.0 × 205.666667 ≈ 1234.0
        XCTAssertEqual(cost.totalCost, 1234.0, accuracy: 0.01)
        // en_US-pinned currency: "$" symbol, comma thousands separator, no fraction.
        XCTAssertEqual(cost.formattedCost, "$1,234")
    }

    func testFormattedCostIsCurrencyString() {
        // Standalone formatter, en_US-pinned: "$0" and "$450".
        XCTAssertEqual(MeetingCost.format(0), "$0")
        XCTAssertEqual(MeetingCost.format(450), "$450")
    }

    func testFormattedCostForZero() {
        let cost = MeetingCostCalculator.calculate(
            attendeeCount: 0,
            durationMinutes: 0,
            hourlyRatePerPerson: 100.0)
        // No attendees/duration ⇒ "$0", currency symbol then zero, no fraction.
        XCTAssertEqual(cost.formattedCost, "$0")
    }

    func testLargeMeeting() {
        // 20 attendees × 90 min × $150/hr = 20 × 1.5 × 150 = $4,500
        let cost = MeetingCostCalculator.calculate(
            attendeeCount: 20,
            durationMinutes: 90,
            hourlyRatePerPerson: 150.0)
        XCTAssertEqual(cost.totalCost, 4500.0, accuracy: 0.001)
        XCTAssertEqual(cost.attendeeCount, 20)
        XCTAssertEqual(cost.durationMinutes, 90)
        XCTAssertEqual(cost.hourlyRatePerPerson, 150.0)
        // en_US-pinned currency: "$4,500" with comma thousands separator.
        XCTAssertEqual(cost.formattedCost, "$4,500")
    }

    func testFractionalDuration() {
        // 30 min is half an hour → 1 attendee × 0.5 × $100 = $50
        let cost = MeetingCostCalculator.calculate(
            attendeeCount: 1,
            durationMinutes: 30,
            hourlyRatePerPerson: 100.0)
        XCTAssertEqual(cost.totalCost, 50.0, accuracy: 0.001)
    }

    func testNegativeAttendeesClampedToZero() {
        // Garbage in, $0 out — never a negative cost.
        let cost = MeetingCostCalculator.calculate(
            attendeeCount: -5,
            durationMinutes: 60,
            hourlyRatePerPerson: 100.0)
        XCTAssertEqual(cost.attendeeCount, 0)
        XCTAssertEqual(cost.totalCost, 0.0, accuracy: 0.001)
    }

    func testNegativeDurationClampedToZero() {
        let cost = MeetingCostCalculator.calculate(
            attendeeCount: 3,
            durationMinutes: -10,
            hourlyRatePerPerson: 100.0)
        XCTAssertEqual(cost.durationMinutes, 0)
        XCTAssertEqual(cost.totalCost, 0.0, accuracy: 0.001)
    }

    func testNegativeRateClampedToZero() {
        let cost = MeetingCostCalculator.calculate(
            attendeeCount: 3,
            durationMinutes: 60,
            hourlyRatePerPerson: -50.0)
        XCTAssertEqual(cost.hourlyRatePerPerson, 0.0)
        XCTAssertEqual(cost.totalCost, 0.0, accuracy: 0.001)
    }

    func testEqualityRequiresMatchingFormattedCost() {
        // MeetingCost has a synthesized Equatable, so formattedCost is part of
        // equality. Two instances with identical numbers but different formatted
        // strings are NOT equal.
        let calculated = MeetingCostCalculator.calculate(
            attendeeCount: 2, durationMinutes: 60, hourlyRatePerPerson: 50.0)
        let manual = MeetingCost(
            attendeeCount: 2,
            durationMinutes: 60,
            hourlyRatePerPerson: 50.0,
            totalCost: 100.0,
            formattedCost: "manual")
        XCTAssertNotEqual(calculated, manual)
    }

    func testIdenticalInputsProduceEqualCosts() {
        // Two calculate() calls with the same inputs produce equal MeetingCosts,
        // including the en_US-pinned formattedCost ("$100").
        let a = MeetingCostCalculator.calculate(
            attendeeCount: 2, durationMinutes: 60, hourlyRatePerPerson: 50.0)
        let b = MeetingCostCalculator.calculate(
            attendeeCount: 2, durationMinutes: 60, hourlyRatePerPerson: 50.0)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.formattedCost, "$100")
    }

    // MARK: - estimate(attendees:duration:hourlyRatePerPerson:)

    func testEstimateFromTimeInterval() {
        // 3600 s = 60 min; 3 attendees × 60 min × $100/hr = $300
        let cost = MeetingCostCalculator.estimate(
            attendees: ["Alice", "Bob", "Carol"],
            duration: 3600.0,
            hourlyRatePerPerson: 100.0)
        XCTAssertEqual(cost.durationMinutes, 60)
        XCTAssertEqual(cost.attendeeCount, 3)
        XCTAssertEqual(cost.totalCost, 300.0, accuracy: 0.001)
    }

    func testEstimateRoundsSecondsToMinutes() {
        // 90 s rounds to 2 min (rounds to nearest), → 1 × (2/60) × $100 ≈ $3.33
        let cost = MeetingCostCalculator.estimate(
            attendees: ["Solo"],
            duration: 90.0,
            hourlyRatePerPerson: 100.0)
        XCTAssertEqual(cost.durationMinutes, 2)
        XCTAssertEqual(cost.totalCost, 100.0 * (2.0 / 60.0), accuracy: 0.001)
    }

    func testEstimateEmptyAttendees() {
        let cost = MeetingCostCalculator.estimate(
            attendees: [],
            duration: 3600.0,
            hourlyRatePerPerson: 100.0)
        XCTAssertEqual(cost.attendeeCount, 0)
        XCTAssertEqual(cost.totalCost, 0.0, accuracy: 0.001)
    }

    func testEstimateZeroDuration() {
        let cost = MeetingCostCalculator.estimate(
            attendees: ["A", "B"],
            duration: 0.0,
            hourlyRatePerPerson: 100.0)
        XCTAssertEqual(cost.durationMinutes, 0)
        XCTAssertEqual(cost.totalCost, 0.0, accuracy: 0.001)
    }

    func testEstimateDeduplicatesAttendees() {
        // estimate() trusts the caller's list — duplicates count as distinct seats.
        // This documents that behavior rather than silently deduplicating names.
        let cost = MeetingCostCalculator.estimate(
            attendees: ["Alice", "Alice", "Bob"],
            duration: 3600.0,
            hourlyRatePerPerson: 100.0)
        XCTAssertEqual(cost.attendeeCount, 3)
        XCTAssertEqual(cost.totalCost, 300.0, accuracy: 0.001)
    }

    func testEstimateMatchesCalculateForWholeMinutes() {
        // estimate() with a whole-minute duration must match calculate() exactly.
        let viaEstimate = MeetingCostCalculator.estimate(
            attendees: ["A", "B", "C", "D"],
            duration: 5400.0, // 90 min
            hourlyRatePerPerson: 150.0)
        let viaCalculate = MeetingCostCalculator.calculate(
            attendeeCount: 4,
            durationMinutes: 90,
            hourlyRatePerPerson: 150.0)
        XCTAssertEqual(viaEstimate, viaCalculate)
    }
}
