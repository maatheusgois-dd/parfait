import XCTest
@testable import Nutola

final class TalkTimeStatsTests: XCTestCase {
    // MARK: - Single speaker

    func testSingleSpeaker() {
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 10, text: "Hello there"),
            TranscriptSegment(speakerID: "me", start: 10, end: 20, text: "world"),
        ]

        let stats = TalkTimeStats.compute(segments: segments, speakers: speakers)

        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].speakerID, "me")
        XCTAssertEqual(stats[0].talkTime, 20, accuracy: 0.001)
        XCTAssertEqual(stats[0].segmentCount, 2)
        XCTAssertEqual(stats[0].percentage, 100, accuracy: 0.001)
    }

    // MARK: - Balanced split

    func testTwoSpeakersBalanced() {
        let speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Alice"),
        ]
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 30, text: "one two three four five"),
            TranscriptSegment(speakerID: "s1", start: 30, end: 60, text: "six seven eight nine ten"),
        ]

        let stats = TalkTimeStats.compute(segments: segments, speakers: speakers)

        XCTAssertEqual(stats.count, 2)
        for s in stats {
            XCTAssertEqual(s.percentage, 50, accuracy: 0.001)
        }
        XCTAssertEqual(stats[0].talkTime, 30, accuracy: 0.001)
        XCTAssertEqual(stats[1].talkTime, 30, accuracy: 0.001)
    }

    // MARK: - Word counting

    func testWordCount() {
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "one two three"),
            TranscriptSegment(speakerID: "me", start: 1, end: 2, text: "four   five"),
            TranscriptSegment(speakerID: "me", start: 2, end: 3, text: "  six  "),
        ]

        let stats = TalkTimeStats.compute(segments: segments, speakers: speakers)

        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].wordCount, 6)
    }

    func testWordCountHelper() {
        XCTAssertEqual(TalkTimeStats.wordCount(in: ""), 0)
        XCTAssertEqual(TalkTimeStats.wordCount(in: "   "), 0)
        XCTAssertEqual(TalkTimeStats.wordCount(in: "one"), 1)
        XCTAssertEqual(TalkTimeStats.wordCount(in: "one two three"), 3)
        XCTAssertEqual(TalkTimeStats.wordCount(in: "  one\ttwo\nthree  "), 3)
    }

    // MARK: - Empty

    func testEmptySegments() {
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        XCTAssertEqual(TalkTimeStats.compute(segments: [], speakers: speakers), [])
    }

    // MARK: - Percentage

    func testPercentageCalculation() throws {
        let speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Alice"),
            Speaker(id: "s2", name: "Bob"),
        ]
        // me: 10s (25%), s1: 20s (50%), s2: 10s (25%) → total 40s
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 10, text: "a b c"),
            TranscriptSegment(speakerID: "s1", start: 10, end: 30, text: "d e f g h"),
            TranscriptSegment(speakerID: "s2", start: 30, end: 40, text: "i j"),
        ]

        let stats = TalkTimeStats.compute(segments: segments, speakers: speakers)
        let byID = Dictionary(uniqueKeysWithValues: stats.map { ($0.speakerID, $0) })

        XCTAssertEqual(stats.count, 3)
        let me = try XCTUnwrap(byID["me"], "missing stats for 'me'")
        let alice = try XCTUnwrap(byID["s1"], "missing stats for 's1'")
        let bob = try XCTUnwrap(byID["s2"], "missing stats for 's2'")
        XCTAssertEqual(me.percentage, 25, accuracy: 0.001)
        XCTAssertEqual(alice.percentage, 50, accuracy: 0.001)
        XCTAssertEqual(bob.percentage, 25, accuracy: 0.001)
        // Percentages should sum to 100.
        let total = stats.reduce(0) { $0 + $1.percentage }
        XCTAssertEqual(total, 100, accuracy: 0.001)
    }

    // MARK: - Sorting

    func testSortingByTalkTimeDescending() {
        let speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Alice"),
            Speaker(id: "s2", name: "Bob"),
        ]
        // Bob (s2) talks longest, then Me, then Alice — order should reflect that.
        let segments = [
            TranscriptSegment(speakerID: "s1", start: 0, end: 5, text: "hi"),
            TranscriptSegment(speakerID: "s2", start: 5, end: 25, text: "hello again"),
            TranscriptSegment(speakerID: "me", start: 25, end: 35, text: "ok"),
        ]

        let stats = TalkTimeStats.compute(segments: segments, speakers: speakers)

        XCTAssertEqual(stats.count, 3)
        XCTAssertEqual(stats.map { $0.speakerID }, ["s2", "me", "s1"])
        XCTAssertEqual(stats[0].name, "Bob")
        XCTAssertEqual(stats[1].name, "Me")
        XCTAssertEqual(stats[2].name, "Alice")
        // Strictly non-increasing.
        for i in 1..<stats.count {
            XCTAssertLessThanOrEqual(stats[i].talkTime, stats[i - 1].talkTime)
        }
    }

    // MARK: - Unknown speaker uses ID as name

    func testUnknownSpeakerFallsBackToID() {
        let segments = [TranscriptSegment(speakerID: "ghost", start: 0, end: 5, text: "boo")]
        let stats = TalkTimeStats.compute(segments: segments, speakers: [])
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].name, "ghost")
    }

    // MARK: - Zero-duration total does not divide by zero

    func testZeroDurationTotalDoesNotDivideByZero() {
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        // All segments have end == start → zero talk time total.
        let segments = [
            TranscriptSegment(speakerID: "me", start: 5, end: 5, text: "hi"),
            TranscriptSegment(speakerID: "me", start: 5, end: 5, text: "there"),
        ]

        let stats = TalkTimeStats.compute(segments: segments, speakers: speakers)

        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].talkTime, 0)
        XCTAssertEqual(stats[0].percentage, 0)
    }
}
