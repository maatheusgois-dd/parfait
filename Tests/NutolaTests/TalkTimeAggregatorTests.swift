import XCTest
@testable import Nutola

final class TalkTimeAggregatorTests: XCTestCase {
    // MARK: - Single speaker, single meeting

    func testSingleSpeakerSingleMeeting() throws {
        let meeting = Meeting(title: "M1", createdAt: Date(), duration: 60)
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 60, text: "talking alone"),
        ]

        let summaries = TalkTimeAggregator.aggregate(
            meetings: [meeting],
            transcripts: [(meeting.id, segments)],
            speakers: [(meeting.id, speakers)])

        XCTAssertEqual(summaries.count, 1)
        let s = try XCTUnwrap(summaries.first)
        XCTAssertEqual(s.speakerID, "me")
        XCTAssertEqual(s.name, "Me")
        XCTAssertEqual(s.totalTalkTime, 60, accuracy: 0.001)
        XCTAssertEqual(s.meetingCount, 1)
        XCTAssertEqual(s.avgTalkTimePerMeeting, 60, accuracy: 0.001)
        XCTAssertEqual(s.percentageOfTotal, 100, accuracy: 0.001)
    }

    // MARK: - Multiple speakers aggregated across meetings

    func testMultipleSpeakersAggregated() throws {
        let m1 = Meeting(title: "M1", createdAt: Date(), duration: 60)
        let m2 = Meeting(title: "M2", createdAt: Date(), duration: 60)
        let speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Alice"),
        ]

        // M1: me 30s, Alice 30s
        let seg1 = [
            TranscriptSegment(speakerID: "me", start: 0, end: 30, text: "hi"),
            TranscriptSegment(speakerID: "s1", start: 30, end: 60, text: "hello"),
        ]
        // M2: me 20s, Alice 40s
        let seg2 = [
            TranscriptSegment(speakerID: "me", start: 0, end: 20, text: "yo"),
            TranscriptSegment(speakerID: "s1", start: 20, end: 60, text: "hey"),
        ]

        let summaries = TalkTimeAggregator.aggregate(
            meetings: [m1, m2],
            transcripts: [(m1.id, seg1), (m2.id, seg2)],
            speakers: [(m1.id, speakers), (m2.id, speakers)])

        let byID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.speakerID, $0) })
        XCTAssertEqual(summaries.count, 2)
        let me = try XCTUnwrap(byID["me"])
        let alice = try XCTUnwrap(byID["s1"])
        XCTAssertEqual(me.totalTalkTime, 50, accuracy: 0.001)
        XCTAssertEqual(alice.totalTalkTime, 70, accuracy: 0.001)
        XCTAssertEqual(me.meetingCount, 2)
        XCTAssertEqual(alice.meetingCount, 2)
    }

    // MARK: - Average per meeting

    func testAvgPerMeeting() throws {
        let m1 = Meeting(title: "M1", createdAt: Date(), duration: 60)
        let m2 = Meeting(title: "M2", createdAt: Date(), duration: 90)
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]

        // M1: 30s, M2: 60s → total 90s across 2 meetings → avg 45s
        let seg1 = [TranscriptSegment(speakerID: "me", start: 0, end: 30, text: "x")]
        let seg2 = [TranscriptSegment(speakerID: "me", start: 0, end: 60, text: "y")]

        let summaries = TalkTimeAggregator.aggregate(
            meetings: [m1, m2],
            transcripts: [(m1.id, seg1), (m2.id, seg2)],
            speakers: [(m1.id, speakers), (m2.id, speakers)])

        let s = try XCTUnwrap(summaries.first)
        XCTAssertEqual(s.totalTalkTime, 90, accuracy: 0.001)
        XCTAssertEqual(s.meetingCount, 2)
        XCTAssertEqual(s.avgTalkTimePerMeeting, 45, accuracy: 0.001)
    }

    // MARK: - Percentage of total

    func testPercentageOfTotal() throws {
        let meeting = Meeting(title: "M1", createdAt: Date(), duration: 60)
        let speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Alice"),
        ]
        // me: 10s, s1: 30s → total 40s → me 25%, s1 75%
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 10, text: "a"),
            TranscriptSegment(speakerID: "s1", start: 10, end: 40, text: "b c d"),
        ]

        let summaries = TalkTimeAggregator.aggregate(
            meetings: [meeting],
            transcripts: [(meeting.id, segments)],
            speakers: [(meeting.id, speakers)])

        let byID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.speakerID, $0) })
        let me = try XCTUnwrap(byID["me"])
        let alice = try XCTUnwrap(byID["s1"])
        XCTAssertEqual(me.percentageOfTotal, 25, accuracy: 0.001)
        XCTAssertEqual(alice.percentageOfTotal, 75, accuracy: 0.001)
        // Percentages should sum to 100.
        let total = summaries.reduce(0) { $0 + $1.percentageOfTotal }
        XCTAssertEqual(total, 100, accuracy: 0.001)
    }

    // MARK: - Empty input

    func testEmptyInput() {
        let summaries = TalkTimeAggregator.aggregate(
            meetings: [],
            transcripts: [],
            speakers: [])
        XCTAssertTrue(summaries.isEmpty)
    }

    // MARK: - Meeting without transcript is skipped

    func testMeetingWithoutTranscript() throws {
        let m1 = Meeting(title: "M1", createdAt: Date(), duration: 60)
        let m2 = Meeting(title: "M2", createdAt: Date(), duration: 0)
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        let seg1 = [TranscriptSegment(speakerID: "me", start: 0, end: 30, text: "x")]

        // m2 has no transcript entry and no segments — should be skipped, not counted.
        let summaries = TalkTimeAggregator.aggregate(
            meetings: [m1, m2],
            transcripts: [(m1.id, seg1)],
            speakers: [(m1.id, speakers), (m2.id, speakers)])

        XCTAssertEqual(summaries.count, 1)
        let s = try XCTUnwrap(summaries.first)
        XCTAssertEqual(s.speakerID, "me")
        XCTAssertEqual(s.meetingCount, 1)
        XCTAssertEqual(s.totalTalkTime, 30, accuracy: 0.001)
    }

    // MARK: - Sorting by talk time descending

    func testSortingByTalkTimeDescending() {
        let m1 = Meeting(title: "M1", createdAt: Date(), duration: 60)
        let m2 = Meeting(title: "M2", createdAt: Date(), duration: 60)
        let speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Alice"),
            Speaker(id: "s2", name: "Bob"),
        ]

        // M1: me 10s, s1 30s, s2 20s
        let seg1 = [
            TranscriptSegment(speakerID: "me", start: 0, end: 10, text: "a"),
            TranscriptSegment(speakerID: "s1", start: 10, end: 40, text: "b"),
            TranscriptSegment(speakerID: "s2", start: 40, end: 60, text: "c"),
        ]
        // M2: me 50s, s1 10s
        let seg2 = [
            TranscriptSegment(speakerID: "me", start: 0, end: 50, text: "d"),
            TranscriptSegment(speakerID: "s1", start: 50, end: 60, text: "e"),
        ]
        // Totals: me 60s, s1 40s, s2 20s → sorted [me, s1, s2]

        let summaries = TalkTimeAggregator.aggregate(
            meetings: [m1, m2],
            transcripts: [(m1.id, seg1), (m2.id, seg2)],
            speakers: [(m1.id, speakers), (m2.id, speakers)])

        XCTAssertEqual(summaries.map { $0.speakerID }, ["me", "s1", "s2"])
        XCTAssertEqual(summaries[0].totalTalkTime, 60, accuracy: 0.001)
        XCTAssertEqual(summaries[1].totalTalkTime, 40, accuracy: 0.001)
        XCTAssertEqual(summaries[2].totalTalkTime, 20, accuracy: 0.001)
    }
}
