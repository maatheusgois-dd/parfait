import XCTest
@testable import Parfait

final class LiveTranscriberTests: XCTestCase {
    func testTurnsGroupConsecutiveSameSpeaker() {
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 0, text: "Hi"),
            TranscriptSegment(speakerID: "me", start: 1, end: 1, text: "there"),
            TranscriptSegment(speakerID: "them", start: 2, end: 2, text: "Hello"),
            TranscriptSegment(speakerID: "me", start: 3, end: 3, text: "again"),
        ]
        let turns = LiveTranscriber.turns(from: segments)
        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns[0].speakerID, "me")
        XCTAssertEqual(turns[0].text, "Hi there")
        XCTAssertEqual(turns[1].speakerID, "them")
        XCTAssertEqual(turns[1].text, "Hello")
        XCTAssertEqual(turns[2].text, "again")
        // Ids are the running index, so ForEach stays stable as segments append.
        XCTAssertEqual(turns.map(\.id), [0, 1, 2])
    }

    func testTurnsEmpty() {
        XCTAssertTrue(LiveTranscriber.turns(from: []).isEmpty)
    }

    func testNameMapsSyntheticSpeakers() {
        XCTAssertEqual(LiveTranscriber.name(for: LiveTranscriber.youSpeakerID), "You")
        XCTAssertEqual(LiveTranscriber.name(for: LiveTranscriber.othersSpeakerID), "Others")
        XCTAssertEqual(LiveTranscriber.name(for: "unmapped"), "unmapped")
    }
}
