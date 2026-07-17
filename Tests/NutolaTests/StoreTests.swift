import XCTest
@testable import Nutola

final class StoreTests: XCTestCase {
    var tmp: URL!
    var archive: MeetingArchive!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-tests-\(UUID().uuidString)")
        archive = MeetingArchive(root: tmp)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
    }

    func makeMeeting(title: String = "Standup") -> Meeting {
        // Whole-millisecond date so it survives the ISO8601 round-trip exactly.
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)
        var m = Meeting(title: title, createdAt: now)
        m.speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Speaker 1"),
        ]
        m.state = .ready
        // save() refuses to (re)create the folder — start-of-recording owns that.
        try? archive.createFolder(for: m.id)
        return m
    }

    func testSaveRefusesToResurrectDeletedMeeting() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.delete(id: m.id)
        // A late pipeline write must not recreate the deleted meeting on disk.
        XCTAssertThrowsError(try archive.save(m))
        XCTAssertNil(archive.meeting(id: m.id))
    }

    func testMeetingRoundTrip() throws {
        let m = makeMeeting()
        try archive.save(m)
        XCTAssertEqual(archive.meeting(id: m.id), m)
        XCTAssertEqual(archive.allMeetings(), [m])
    }

    func testTranscriptRoundTrip() throws {
        let m = makeMeeting()
        try archive.save(m)
        let segments = [
            TranscriptSegment(speakerID: "me", start: 0, end: 2.5, text: "Morning everyone."),
            TranscriptSegment(speakerID: "s1", start: 3, end: 6, text: "Hey! Ready to start?"),
        ]
        try archive.saveTranscript(segments, for: m.id)
        XCTAssertEqual(archive.transcript(for: m.id), segments)
    }

    func testSummaryRoundTrip() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("## TL;DR\nShipped it.", for: m.id)
        XCTAssertEqual(archive.summary(for: m.id), "## TL;DR\nShipped it.")
    }

    // MARK: - Summary edit history

    func testSaveSummarySnapshotsPreviousVersion() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("v1", for: m.id)
        XCTAssertEqual(archive.summaryHistory(for: m.id), [])
        // Overwriting with different content creates a snapshot of v1.
        try archive.saveSummary("v2", for: m.id)
        let history = archive.summaryHistory(for: m.id)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].markdown, "v1")
        XCTAssertEqual(archive.summary(for: m.id), "v2")
    }

    func testSaveSummaryDoesNotSnapshotIdenticalContent() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("same", for: m.id)
        try archive.saveSummary("same", for: m.id)
        XCTAssertEqual(archive.summaryHistory(for: m.id), [])
    }

    func testSaveSummaryDoesNotSnapshotEmptyToContent() throws {
        let m = makeMeeting()
        try archive.save(m)
        // First write from empty → no snapshot (not an edit).
        try archive.saveSummary("first real summary", for: m.id)
        XCTAssertEqual(archive.summaryHistory(for: m.id), [])
    }

    func testHistoryIsNewestFirst() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("v1", for: m.id)
        try archive.saveSummary("v2", for: m.id)
        try archive.saveSummary("v3", for: m.id)
        let history = archive.summaryHistory(for: m.id)
        XCTAssertEqual(history.count, 2)
        // Newest snapshot first: v2 was displaced by v3, v1 by v2.
        XCTAssertEqual(history[0].markdown, "v2")
        XCTAssertEqual(history[1].markdown, "v1")
    }

    func testHistoryPrunesToMax() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("v0", for: m.id)
        // Write more than maxSummaryHistory versions.
        for i in 1...(MeetingArchive.maxSummaryHistory + 5) {
            try archive.saveSummary("v\(i)", for: m.id)
        }
        let history = archive.summaryHistory(for: m.id)
        XCTAssertEqual(history.count, MeetingArchive.maxSummaryHistory)
    }

    func testRestoreSummarySwapsCurrentAndIsReversible() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("v1", for: m.id)
        try archive.saveSummary("v2", for: m.id)
        let v1Snapshot = archive.summaryHistory(for: m.id).first { $0.markdown == "v1" }!
        // Restore v1: current "v2" becomes a snapshot, summary becomes v1.
        XCTAssertTrue(archive.restoreSummary(at: v1Snapshot.timestamp, for: m.id))
        XCTAssertEqual(archive.summary(for: m.id), "v1")
        // v2 is now in history, so the restore is reversible.
        let v2Snapshot = archive.summaryHistory(for: m.id).first { $0.markdown == "v2" }!
        XCTAssertTrue(archive.restoreSummary(at: v2Snapshot.timestamp, for: m.id))
        XCTAssertEqual(archive.summary(for: m.id), "v2")
    }

    func testRestoreSummaryUnknownTimestampFails() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("v1", for: m.id)
        XCTAssertFalse(archive.restoreSummary(at: Date(timeIntervalSince1970: 0), for: m.id))
    }

    func testDeleteMeetingRemovesHistory() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSummary("v1", for: m.id)
        try archive.saveSummary("v2", for: m.id)
        XCTAssertFalse(archive.summaryHistory(for: m.id).isEmpty)
        try archive.delete(id: m.id)
        XCTAssertEqual(archive.summaryHistory(for: m.id), [])
    }

    func testSideNotesRoundTrip() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.saveSideNotes("- Action: follow up with design\n- Blocker: API latency", for: m.id)
        XCTAssertEqual(archive.sideNotes(for: m.id), "- Action: follow up with design\n- Blocker: API latency")
        XCTAssertEqual(archive.summary(for: m.id), "")
    }

    func testDelete() throws {
        let m = makeMeeting()
        try archive.save(m)
        try archive.delete(id: m.id)
        XCTAssertNil(archive.meeting(id: m.id))
        XCTAssertEqual(archive.allMeetings(), [])
    }

    func testSearchRanksTitleAboveTranscript() throws {
        let titled = makeMeeting(title: "Budget review")
        try archive.save(titled)
        var other = makeMeeting(title: "Standup")
        other.createdAt = Date(timeIntervalSinceNow: -60)
        try archive.save(other)
        try archive.saveTranscript(
            [TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "We touched on the budget briefly.")],
            for: other.id
        )
        let hits = archive.search("budget")
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].meeting.id, titled.id)
        XCTAssertEqual(hits[1].meeting.id, other.id)
        XCTAssertTrue(hits[1].excerpts[0].contains("Me @ 0:00"))
    }

    func testSearchSkipsTranscriptDecodeForNonMatchingMeetings() throws {
        // A meeting whose transcript can't contain the query word should still
        // be scored correctly (0 from transcript) and skipped at the JSON-decode
        // level — the pre-filter must not suppress title/summary/attendee hits.
        let m = makeMeeting(title: "Sprint planning")
        try archive.save(m)
        try archive.saveTranscript(
            [TranscriptSegment(speakerID: "me", start: 0, end: 1, text: "Completely unrelated content about weather.")],
            for: m.id
        )
        // Title match only — transcript pre-filter skips the decode, score comes from title.
        let hits = archive.search("sprint")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].meeting.id, m.id)
        XCTAssertEqual(hits[0].score, 10) // title only, no transcript contribution
    }

    func testSearchPreFilterStillFindsTranscriptMatches() throws {
        // Verify the pre-filter doesn't false-negative on real transcript hits.
        let m = makeMeeting(title: "Random title")
        try archive.save(m)
        try archive.saveTranscript(
            [TranscriptSegment(speakerID: "me", start: 10, end: 12, text: "We need to discuss the migration plan.")],
            for: m.id
        )
        let hits = archive.search("migration")
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].excerpts.contains(where: { $0.contains("migration") }))
    }

    func testSearchNoResults() {
        XCTAssertTrue(archive.search("zebra").isEmpty)
        XCTAssertTrue(archive.search("   ").isEmpty)
    }
}
