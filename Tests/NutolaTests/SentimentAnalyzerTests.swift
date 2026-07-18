import XCTest
@testable import Nutola

final class SentimentAnalyzerTests: XCTestCase {
    // MARK: - Positive

    func testPositiveSentiment() {
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 5,
                             text: "This is great, excellent work today."),
        ]
        let results = SentimentAnalyzer.analyze(segments: segments, speakers: speakers)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].sentiment, .positive)
        XCTAssertEqual(results[0].speakerID, "me")
        XCTAssertEqual(results[0].speakerName, "Me")
        XCTAssertEqual(results[0].segmentIndex, 0)
    }

    // MARK: - Negative

    func testNegativeSentiment() {
        let speakers = [Speaker(id: "s1", name: "Alice")]
        let segments = [
            TranscriptSegment(speakerID: "s1", start: 0, end: 5,
                             text: "I have a problem and a real concern with this."),
        ]
        let results = SentimentAnalyzer.analyze(segments: segments, speakers: speakers)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].sentiment, .negative)
        XCTAssertEqual(results[0].speakerName, "Alice")
    }

    // MARK: - Critical (precedence over negative and positive)

    func testCriticalSentiment() {
        let speakers = [Speaker(id: "s1", name: "Alice")]
        let segments = [
            TranscriptSegment(speakerID: "s1", start: 0, end: 5,
                             text: "This is urgent, a blocker and a real risk for the launch."),
        ]
        let results = SentimentAnalyzer.analyze(segments: segments, speakers: speakers)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].sentiment, .critical)
    }

    func testCriticalBeatsNegativeWhenBothPresent() {
        // Precedence: critical > negative > positive. A segment mentioning
        // "problem" (negative) and "blocker" (critical) reads critical.
        let speakers = [Speaker(id: "s1", name: "Alice")]
        let segments = [
            TranscriptSegment(speakerID: "s1", start: 0, end: 5,
                             text: "We have a problem and this is a blocker."),
        ]
        let results = SentimentAnalyzer.analyze(segments: segments, speakers: speakers)
        XCTAssertEqual(results[0].sentiment, .critical)
    }

    // MARK: - Neutral default

    func testNeutralDefault() {
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 5,
                             text: "Let's talk about the agenda for today."),
        ]
        let results = SentimentAnalyzer.analyze(segments: segments, speakers: speakers)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].sentiment, .neutral)
        XCTAssertEqual(results[0].score, 0, accuracy: 0.0001)
    }

    // MARK: - Score calculation

    func testScoreCalculation() {
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        // 6 words, 2 positive keywords → score = 2/6 ≈ 0.333.
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 5,
                             text: "great love the meeting notes today"),
        ]
        let results = SentimentAnalyzer.analyze(segments: segments, speakers: speakers)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].sentiment, .positive)
        XCTAssertEqual(results[0].score, 2.0 / 6.0, accuracy: 0.0001)
        // Bounded in [0, 1].
        XCTAssertGreaterThanOrEqual(results[0].score, 0)
        XCTAssertLessThanOrEqual(results[0].score, 1)
    }

    func testScoreIsBounded() {
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        // Every word is a keyword → score should be 1.0, never above.
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 5,
                             text: "great love agree"),
        ]
        let results = SentimentAnalyzer.analyze(segments: segments, speakers: speakers)
        XCTAssertEqual(results[0].score, 1.0, accuracy: 0.0001)
    }

    // MARK: - Empty input

    func testEmptySegments() {
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        let results = SentimentAnalyzer.analyze(segments: [], speakers: speakers)
        XCTAssertTrue(results.isEmpty)
    }

    func testEmptySpeakersStillClassifies() {
        // No speakers list — name falls back to speakerID.
        let segments = [
            TranscriptSegment(speakerID: "ghost", start: 0, end: 3, text: "great point"),
        ]
        let results = SentimentAnalyzer.analyze(segments: segments, speakers: [])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].sentiment, .positive)
        XCTAssertEqual(results[0].speakerName, "ghost")
    }

    // MARK: - Multiple speakers

    func testMultipleSpeakers() {
        let speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Alice"),
            Speaker(id: "s2", name: "Bob"),
        ]
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 5,
                             text: "This is excellent, great plan."),
            TranscriptSegment(speakerID: "s1", start: 5, end: 10,
                             text: "I disagree, this is wrong."),
            TranscriptSegment(speakerID: "s2", start: 10, end: 15,
                             text: "Let's review the notes."),
        ]
        let results = SentimentAnalyzer.analyze(segments: segments, speakers: speakers)

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].speakerID, "me")
        XCTAssertEqual(results[0].sentiment, .positive)
        XCTAssertEqual(results[1].speakerID, "s1")
        XCTAssertEqual(results[1].sentiment, .negative)
        XCTAssertEqual(results[2].speakerID, "s2")
        XCTAssertEqual(results[2].sentiment, .neutral)

        // Names resolved from the speakers list, not bare IDs.
        XCTAssertEqual(results[0].speakerName, "Me")
        XCTAssertEqual(results[1].speakerName, "Alice")
        XCTAssertEqual(results[2].speakerName, "Bob")

        // Segment indices track the input order.
        XCTAssertEqual(results.map(\.segmentIndex), [0, 1, 2])
    }

    // MARK: - Punctuation robustness

    func testPunctuationStripped() {
        // "great!" and "love," should still register as keywords.
        let speakers = [Speaker(id: "me", name: "Me", isMe: true)]
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 3,
                             text: "great! love, agree."),
        ]
        let results = SentimentAnalyzer.analyze(segments: segments, speakers: speakers)
        XCTAssertEqual(results[0].sentiment, .positive)
        XCTAssertEqual(results[0].score, 1.0, accuracy: 0.0001)
    }

    // MARK: - Identifiable

    func testSpeakerSentimentID() {
        let entry = SpeakerSentiment(
            speakerID: "s1", speakerName: "Alice",
            sentiment: .positive, score: 0.5, segmentIndex: 3)
        XCTAssertEqual(entry.id, "s1-3")
    }

    // MARK: - Sentiment metadata

    func testSentimentEmojiAndColorNonEmpty() {
        // Every case has a distinct emoji and a 6-hex color.
        for sentiment in Sentiment.allCases {
            XCTAssertFalse(sentiment.emoji.isEmpty, "emoji empty for \(sentiment)")
            XCTAssertTrue(sentiment.color.hasPrefix("#"), "color not hex for \(sentiment)")
            XCTAssertEqual(sentiment.color.count, 7, "color not 6-hex for \(sentiment)")
        }
    }
}
