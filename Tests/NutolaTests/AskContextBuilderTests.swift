import XCTest
@testable import Nutola

final class AskContextBuilderTests: XCTestCase {
    var tmp: URL!
    var archive: MeetingArchive!

    override func setUp() {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nutola-ask-tests-\(UUID().uuidString)")
        archive = MeetingArchive(root: tmp)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeMeeting(title: String = "Roadmap sync") -> Meeting {
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)
        var m = Meeting(title: title, createdAt: now)
        m.state = .ready
        try? archive.createFolder(for: m.id)
        return m
    }

    func testEnrichLibraryPromptIncludesMeetingData() throws {
        let meeting = makeMeeting()
        try archive.save(meeting)
        try archive.saveSummary("# Roadmap sync\n\nDecided to ship folders.", for: meeting.id)

        let prompt = ClaudeDesktopPrompt.library(question: "Summarize my meetings this week")
        let enriched = AskContextBuilder.enrichForCLI(prompt, archive: archive)

        XCTAssertTrue(enriched.contains("Meeting data from Nutola"))
        XCTAssertTrue(enriched.contains("Roadmap sync"))
        XCTAssertTrue(enriched.contains("Decided to ship folders"))
        XCTAssertNotEqual(enriched, prompt)
    }

    func testEnrichReturnsPromptWhenNoMeetings() {
        let prompt = ClaudeDesktopPrompt.library(question: "Summarize my meetings this week")
        let enriched = AskContextBuilder.enrichForCLI(prompt, archive: archive)
        XCTAssertEqual(enriched, prompt)
    }

    func testOnDeviceIncludesSummariesNotJustList() throws {
        let withNotes = makeMeeting(title: "All Hands")
        try archive.save(withNotes)
        try archive.saveSummary("## TL;DR\nShipped folders feature.", for: withNotes.id)

        let withoutNotes = makeMeeting(title: "Empty call")
        try archive.save(withoutNotes)

        let prompt = ClaudeDesktopPrompt.library(question: "Summarize my meetings this week")
        let enriched = AskContextBuilder.enrichForAsk(prompt, archive: archive, limits: .onDevice)

        XCTAssertTrue(enriched.contains("Shipped folders"))
        XCTAssertTrue(enriched.contains("All Hands"))
        XCTAssertFalse(enriched.contains("## Recent meetings"))
    }

    func testOnDeviceLimitsStayWithinBudget() throws {
        for i in 0..<12 {
            let meeting = makeMeeting(title: "Meeting \(i)")
            try archive.save(meeting)
            try archive.saveSummary(
                String(repeating: "word ", count: 200) + "decision \(i)",
                for: meeting.id)
        }

        let prompt = ClaudeDesktopPrompt.library(question: "Summarize my meetings this week")
        let enriched = AskContextBuilder.enrichForAsk(prompt, archive: archive, limits: .onDevice)

        XCTAssertTrue(enriched.contains("Meeting data from Nutola"))
        XCTAssertLessThanOrEqual(enriched.count, AskContextBuilder.Limits.onDevice.maxTotalChars! + 32)
    }
}
