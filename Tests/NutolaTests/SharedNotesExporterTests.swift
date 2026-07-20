import XCTest
@testable import Nutola

final class SharedNotesExporterTests: XCTestCase {
    // MARK: - fixtures

    private func sampleMeeting() -> Meeting {
        var m = Meeting(title: "Sprint Planning", createdAt: Date(timeIntervalSince1970: 1_750_000_000))
        m.duration = 30 * 60
        m.speakers = [
            Speaker(id: "me", name: "Me", isMe: true),
            Speaker(id: "s1", name: "Alice"),
        ]
        return m
    }

    private func sampleTranscript() -> [TranscriptTurn] {
        [
            TranscriptTurn(id: "me-0", speakerID: "me", start: 0, end: 4, text: "Welcome everyone.", segmentCount: 1),
            TranscriptTurn(id: "s1-65", speakerID: "s1", start: 65, end: 70, text: "Thanks for hosting.", segmentCount: 1),
        ]
    }

    private func sampleActionItems() -> [ActionItem] {
        [
            ActionItem(text: "Send the recap", owner: "Alice", isChecked: false, lineNumber: 1),
            ActionItem(text: "File the ticket", owner: nil, isChecked: true, lineNumber: 2),
        ]
    }

    private func sampleSummary() -> String {
        "# Sprint Planning\n\n## TL;DR\nWe aligned on the Q3 scope."
    }

    // MARK: - exportHTML

    func testExportHTMLContainsTitle() {
        let html = SharedNotesExporter.exportHTML(
            meeting: sampleMeeting(),
            summary: sampleSummary(),
            transcript: sampleTranscript(),
            actionItems: sampleActionItems())
        XCTAssertTrue(html.contains("<title>Sprint Planning</title>"))
        XCTAssertTrue(html.contains("<h1>Sprint Planning</h1>"))
    }

    func testExportHTMLContainsSummary() {
        let html = SharedNotesExporter.exportHTML(
            meeting: sampleMeeting(),
            summary: sampleSummary(),
            transcript: sampleTranscript(),
            actionItems: sampleActionItems())
        XCTAssertTrue(html.contains("We aligned on the Q3 scope."))
        XCTAssertTrue(html.contains("TL;DR"))
    }

    func testExportHTMLContainsTranscript() {
        let html = SharedNotesExporter.exportHTML(
            meeting: sampleMeeting(),
            summary: sampleSummary(),
            transcript: sampleTranscript(),
            actionItems: sampleActionItems())
        XCTAssertTrue(html.contains("<span class=\"speaker\">Me</span>"))
        XCTAssertTrue(html.contains("<span class=\"speaker\">Alice</span>"))
        XCTAssertTrue(html.contains("Welcome everyone."))
        XCTAssertTrue(html.contains("Thanks for hosting."))
        // Timestamps from the turn starts.
        XCTAssertTrue(html.contains("0:00"))
        XCTAssertTrue(html.contains("1:05"))
    }

    func testExportHTMLContainsActionItems() {
        let html = SharedNotesExporter.exportHTML(
            meeting: sampleMeeting(),
            summary: sampleSummary(),
            transcript: sampleTranscript(),
            actionItems: sampleActionItems())
        XCTAssertTrue(html.contains("Send the recap"))
        XCTAssertTrue(html.contains("File the ticket"))
        XCTAssertTrue(html.contains("Action items"))
        // Owner rendered inline.
        XCTAssertTrue(html.contains("Alice"))
    }

    func testExportHTMLIsSelfContained() {
        let html = SharedNotesExporter.exportHTML(
            meeting: sampleMeeting(),
            summary: sampleSummary(),
            transcript: sampleTranscript(),
            actionItems: sampleActionItems())
        XCTAssertFalse(html.contains("<link"))
        XCTAssertFalse(html.contains("<script src="))
        XCTAssertFalse(html.contains("<script"))
    }

    func testExportHTMLHasDarkTheme() {
        let html = SharedNotesExporter.exportHTML(
            meeting: sampleMeeting(),
            summary: sampleSummary(),
            transcript: sampleTranscript(),
            actionItems: sampleActionItems())
        XCTAssertTrue(html.contains("background"))
        XCTAssertTrue(html.contains("#1") || html.contains("#2") || html.contains("#14"))
    }

    func testExportToFileReturnsURL() throws {
        let url = try SharedNotesExporter.exportToFile(
            meeting: sampleMeeting(),
            summary: sampleSummary(),
            transcript: sampleTranscript(),
            actionItems: sampleActionItems())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        let html = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(html.contains("<title>Sprint Planning</title>"))
        try? FileManager.default.removeItem(at: url)
    }

    func testExportHTMLWithEmptyData() {
        let m = Meeting(title: "Empty", createdAt: Date())
        let html = SharedNotesExporter.exportHTML(
            meeting: m,
            summary: "",
            transcript: [],
            actionItems: [])
        XCTAssertTrue(html.contains("<!doctype html>"))
        XCTAssertTrue(html.contains("<title>Empty</title>"))
        XCTAssertTrue(html.contains("<html"))
        XCTAssertTrue(html.contains("</html>"))
        // Empty sections are simply omitted — still a valid page.
        XCTAssertFalse(html.contains("Summary"))
        XCTAssertFalse(html.contains("Transcript"))
        XCTAssertFalse(html.contains("Action items"))
    }
}
