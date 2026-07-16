import XCTest
@testable import Parfait

final class ProcessingPipelineTests: XCTestCase {
    private func seg(_ speakerID: String, _ text: String) -> TranscriptSegment {
        TranscriptSegment(speakerID: speakerID, start: 0, end: 0, text: text)
    }

    // MARK: - sameContent (drives skipping a redundant improvement pass)

    func testSameContentIgnoresSpeakerLabelsAndPunctuation() {
        // Live approximation vs. diarized transcript: same words, different speaker
        // ids and punctuation. The improvement pass would add nothing, so skip it.
        let live = [
            seg("me", "Let's ship the release today"),
            seg("them", "Sounds good, I'll cut the branch"),
        ]
        let accurate = [
            seg("s1", "Let's ship the release today."),
            seg("Conrad", "Sounds good — I'll cut the branch"),
        ]
        XCTAssertTrue(ProcessingPipeline.sameContent(live, accurate))
    }

    func testSameContentFalseWhenWordsDiffer() {
        let live = [seg("me", "ship the release today")]
        let accurate = [seg("s1", "ship the release tomorrow")]
        XCTAssertFalse(ProcessingPipeline.sameContent(live, accurate))
    }

    func testSameContentFalseWhenAccurateAddsWords() {
        // The batch transcript usually recovers words the live pass dropped.
        let live = [seg("me", "quarterly numbers")]
        let accurate = [seg("s1", "the quarterly numbers look strong")]
        XCTAssertFalse(ProcessingPipeline.sameContent(live, accurate))
    }
}

// MARK: - AppleSummarizer.chunk / splitLong (long-line splitting)

final class AppleSummarizerChunkTests: XCTestCase {
    private let budget = 100 // small budget for testability

    func testChunkShortLineUnchanged() {
        let chunks = AppleSummarizer.chunk("short line")
        XCTAssertEqual(chunks, ["short line"])
    }

    func testChunkMultipleShortLinesInOneChunk() {
        let text = "line one\nline two\nline three"
        let chunks = AppleSummarizer.chunk(text)
        // All three fit within the default budget, so they stay together.
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], text)
    }

    func testSplitLongLineExceedingBudget() {
        // A single line longer than the budget is split at word boundaries.
        let long = String(repeating: "word ", count: 30) // 150 chars > budget
        let pieces = AppleSummarizer.splitLong(long, maxChars: budget)
        for piece in pieces {
            XCTAssertLessThanOrEqual(piece.count, budget + 1, "piece exceeds budget: \(piece.count)")
        }
        XCTAssertGreaterThan(pieces.count, 1)
    }

    func testSplitLongSingleWordExceedingBudget() {
        // A single word longer than the budget is hard-split mid-word.
        let mega = String(repeating: "a", count: 250)
        let pieces = AppleSummarizer.splitLong(mega, maxChars: budget)
        for piece in pieces {
            XCTAssertLessThanOrEqual(piece.count, budget)
        }
        XCTAssertGreaterThan(pieces.count, 2)
        // No data lost — concatenation recovers the original.
        XCTAssertEqual(pieces.joined(), mega)
    }

    func testChunkHandlesLineLongerThanBudget() {
        // This was the bug: a single line > budget would pass through unsplit,
        // overflowing the context window. Now it's hard-split.
        let budget = AppleSummarizer.inputBudgetChars
        let long = String(repeating: "word ", count: budget / 3 + 10) // well over budget
        XCTAssertGreaterThan(long.count, budget)
        let chunks = AppleSummarizer.chunk(long)
        XCTAssertGreaterThan(chunks.count, 1)
        for c in chunks {
            XCTAssertLessThanOrEqual(c.count, budget + 1)
        }
    }
}
