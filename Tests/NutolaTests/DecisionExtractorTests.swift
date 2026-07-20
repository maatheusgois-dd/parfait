import XCTest
@testable import Nutola

final class DecisionExtractorTests: XCTestCase {
    private let speakers = [
        Speaker(id: "me", name: "Me", isMe: true),
        Speaker(id: "s1", name: "Alice"),
    ]

    // MARK: - Phrase matching

    func testExtractLetsGoWith() {
        let segments = [TranscriptSegment(speakerID: "me", start: 0, end: 2, text: "let's go with option A")]
        let decisions = DecisionExtractor.extract(from: segments, speakers: speakers)
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.quote, "let's go with option A")
    }

    func testExtractWeDecided() {
        let segments = [TranscriptSegment(speakerID: "s1", start: 10, end: 14, text: "we decided to launch next week")]
        let decisions = DecisionExtractor.extract(from: segments, speakers: speakers)
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.quote, "we decided to launch next week")
    }

    func testExtractMultipleDecisions() {
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "let's go with option A"),
            TranscriptSegment(speakerID: "s1", start: 5, end: 6, text: "we decided to launch next week"),
            TranscriptSegment(speakerID: "me", start: 10, end: 11, text: "let's do the migration on Friday"),
        ]
        let decisions = DecisionExtractor.extract(from: segments, speakers: speakers)
        XCTAssertEqual(decisions.count, 3)
    }

    func testNoDecisionInRegularText() {
        let segments = [TranscriptSegment(speakerID: "me", start: 0, end: 2, text: "I think the weather is nice today")]
        let decisions = DecisionExtractor.extract(from: segments, speakers: speakers)
        XCTAssertTrue(decisions.isEmpty)
    }

    func testCaseInsensitive() {
        let segments = [TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "LET'S GO WITH PLAN B")]
        let decisions = DecisionExtractor.extract(from: segments, speakers: speakers)
        XCTAssertEqual(decisions.count, 1)
    }

    // MARK: - Metadata

    func testSpeakerNameResolved() {
        let segments = [TranscriptSegment(speakerID: "s1", start: 0, end: 1, text: "we should use the new framework")]
        let decisions = DecisionExtractor.extract(from: segments, speakers: speakers)
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.speakerName, "Alice")
        XCTAssertEqual(decisions.first?.speakerID, "s1")
    }

    func testTimestampExtracted() {
        let segments = [TranscriptSegment(speakerID: "me", start: 125, end: 130, text: "the plan is to ship in Q3")]
        let decisions = DecisionExtractor.extract(from: segments, speakers: speakers)
        XCTAssertEqual(decisions.first?.timestamp, 125)
    }

    // MARK: - Deduplication

    func testDeduplication() {
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "let's go with option A for the redesign"),
            TranscriptSegment(speakerID: "s1", start: 30, end: 31, text: "let's go with option A for the redesign"),
        ]
        let decisions = DecisionExtractor.extract(from: segments, speakers: speakers)
        XCTAssertEqual(decisions.count, 1)
    }
}
