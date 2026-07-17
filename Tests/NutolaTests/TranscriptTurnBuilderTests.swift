import XCTest
@testable import Nutola

final class TranscriptTurnBuilderTests: XCTestCase {
    func testTurnsGroupConsecutiveSameSpeaker() {
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "Hi"),
            TranscriptSegment(speakerID: "me", start: 1, end: 2, text: "there"),
            TranscriptSegment(speakerID: "s1", start: 2, end: 3, text: "Hello"),
            TranscriptSegment(speakerID: "me", start: 3, end: 4, text: "again"),
        ]
        let turns = TranscriptTurnBuilder.turns(from: segments)
        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns[0].id, "me-0")
        XCTAssertEqual(turns[0].speakerID, "me")
        XCTAssertEqual(turns[0].text, "Hi there")
        XCTAssertEqual(turns[0].start, 0)
        XCTAssertEqual(turns[0].end, 2)
        XCTAssertEqual(turns[0].segmentCount, 2)
        XCTAssertEqual(turns[1].speakerID, "s1")
        XCTAssertEqual(turns[1].text, "Hello")
        XCTAssertEqual(turns[1].end, 3)
        XCTAssertEqual(turns[2].text, "again")
        XCTAssertEqual(turns[2].start, 3)
        XCTAssertEqual(turns[2].end, 4)
    }

    func testTurnsEmpty() {
        XCTAssertTrue(TranscriptTurnBuilder.turns(from: []).isEmpty)
    }

    func testTurnEndTimeUsesLastSegment() {
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 5, text: "a"),
            TranscriptSegment(speakerID: "me", start: 5, end: 12, text: "b"),
        ]
        let turns = TranscriptTurnBuilder.turns(from: segments)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].end, 12)
        XCTAssertEqual(turns[0].segmentCount, 2)
    }
}
