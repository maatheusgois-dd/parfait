import XCTest
@testable import Nutola

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

    // MARK: - appendOffset / offsetSegments

    private func segAt(_ speakerID: String, _ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TranscriptSegment {
        TranscriptSegment(speakerID: speakerID, start: start, end: end, text: text)
    }

    func testAppendOffsetZeroWhenNoPriorSegments() {
        let meeting = Meeting(title: "x", createdAt: Date())
        XCTAssertEqual(ProcessingPipeline.appendOffset(meeting: meeting, prior: []), 0)
    }

    func testAppendOffsetIsMaxOfDurationAndPriorEnd() {
        var meeting = Meeting(title: "x", createdAt: Date())
        meeting.duration = 120
        // A resumed session: prior transcript already runs to 200s, longer than
        // the 120s duration, so the new segments must append past 200s, not 120s.
        let prior = [segAt("me", 195, 200, "last words of first leg")]
        XCTAssertEqual(ProcessingPipeline.appendOffset(meeting: meeting, prior: prior), 200)
    }

    func testAppendOffsetPicksDurationWhenPriorShorter() {
        var meeting = Meeting(title: "x", createdAt: Date())
        meeting.duration = 300
        let prior = [segAt("me", 10, 50, "short prior")]
        XCTAssertEqual(ProcessingPipeline.appendOffset(meeting: meeting, prior: prior), 300)
    }

    func testOffsetSegmentsShiftsBothBounds() {
        let original = [
            segAt("s1", 0, 2, "hi"),
            segAt("s2", 5, 8, "hello"),
        ]
        let shifted = ProcessingPipeline.offsetSegments(original, by: 100)
        XCTAssertEqual(shifted[0].start, 100)
        XCTAssertEqual(shifted[0].end, 102)
        XCTAssertEqual(shifted[1].start, 105)
        XCTAssertEqual(shifted[1].end, 108)
        // Identity preserved otherwise.
        XCTAssertEqual(shifted[0].speakerID, "s1")
        XCTAssertEqual(shifted[0].text, "hi")
    }

    func testOffsetSegmentsZeroIsIdentity() {
        let original = [segAt("me", 1, 2, "x")]
        XCTAssertEqual(ProcessingPipeline.offsetSegments(original, by: 0), original)
    }

    // MARK: - mergingSpeakers

    func testMergingSpeakersKeepsExistingAndAppendsNewById() {
        let existing = [Speaker(id: "me", name: "Me", isMe: true), Speaker(id: "s1", name: "Priya")]
        let incoming = [Speaker(id: "s1", name: "Priya (dup)"), Speaker(id: "s2", name: "Sam")]
        let merged = ProcessingPipeline.mergingSpeakers(existing: existing, new: incoming)
        // Existing kept; new appended; dup (same id) dropped — so 3 total, not 4.
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].id, "me")
        XCTAssertEqual(merged[1].id, "s1")
        XCTAssertEqual(merged[1].name, "Priya") // existing name wins
        XCTAssertEqual(merged[2].id, "s2")
    }

    func testMergingSpeakersEmptyExistingAppendsAll() {
        let incoming = [Speaker(id: "s1", name: "Priya"), Speaker(id: "s2", name: "Sam")]
        let merged = ProcessingPipeline.mergingSpeakers(existing: [], new: incoming)
        XCTAssertEqual(merged, incoming)
    }

    func testMergingSpeakersEmptyIncomingKeepsExisting() {
        let existing = [Speaker(id: "me", name: "Me", isMe: true)]
        let merged = ProcessingPipeline.mergingSpeakers(existing: existing, new: [])
        XCTAssertEqual(merged, existing)
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
