import XCTest
@testable import Parfait

final class ClaudeDesktopTests: XCTestCase {
    func testNewChatURLSchemeHostPath() {
        let url = ClaudeDesktop.newChatURL(prompt: "hello")!
        XCTAssertEqual(url.scheme, "claude")
        XCTAssertEqual(url.host, "claude.ai")
        XCTAssertEqual(url.path, "/new")
    }

    func testNewChatURLPercentEncodesSpecialCharacters() {
        let prompt = #"Hello, world! Use tool: get_meeting id=abc&def #tag "quoted" 100%"#
        let url = ClaudeDesktop.newChatURL(prompt: prompt)!
        XCTAssertEqual(
            url.absoluteString,
            #"claude://claude.ai/new?q=Hello,%20world!%20Use%20tool:%20get_meeting%20id%3Dabc%26def%20%23tag%20%22quoted%22%20100%25"#
        )
    }

    func testNewChatURLEncodesPlusSign() {
        // "C++ migration" must not arrive with a raw + that a form-decoder reads as a space.
        let url = ClaudeDesktop.newChatURL(prompt: "C++ migration")!
        XCTAssertTrue(url.absoluteString.contains("C%2B%2B"))
        XCTAssertFalse(url.query!.contains("+"))
        let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value
        XCTAssertEqual(decoded, "C++ migration")
    }

    func testNewChatURLRoundTripsOrdinaryPrompt() {
        let prompt = "What did we decide about the Q3 launch?"
        let url = ClaudeDesktop.newChatURL(prompt: prompt)!
        let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value
        XCTAssertEqual(decoded, prompt)
    }

    func testNewChatURLTruncatesLongPrompts() {
        let huge = String(repeating: "a", count: ClaudeDesktop.maxPromptLength + 500)
        let url = ClaudeDesktop.newChatURL(prompt: huge)!
        let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value
        XCTAssertEqual(decoded?.count, ClaudeDesktop.maxPromptLength)
    }

    func testNewChatURLHandlesEmptyPrompt() {
        let url = ClaudeDesktop.newChatURL(prompt: "")
        XCTAssertEqual(url?.query, "q=")
    }

    func testMeetingPromptNamesConnectorToolsAndMeeting() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let prompt = ClaudeDesktopPrompt.meeting(id: id, title: "Roadmap sync", date: date, question: "What did we decide?")
        XCTAssertTrue(prompt.contains("parfait"))
        XCTAssertTrue(prompt.contains("get_meeting"))
        XCTAssertTrue(prompt.contains("get_transcript"))
        XCTAssertTrue(prompt.contains(id.uuidString))
        XCTAssertTrue(prompt.contains("Roadmap sync"))
        XCTAssertTrue(prompt.contains("What did we decide?"))
    }

    func testMeetingPromptFallsBackOnEmptyQuestion() {
        let prompt = ClaudeDesktopPrompt.meeting(id: UUID(), title: "1:1", date: Date(), question: "   ")
        XCTAssertFalse(prompt.contains("Question: \n"))
        XCTAssertTrue(prompt.contains("overview"))
    }

    func testLibraryPromptNamesConnectorAndTools() {
        let prompt = ClaudeDesktopPrompt.library(question: "When did I last talk about hiring?")
        XCTAssertTrue(prompt.contains("parfait"))
        XCTAssertTrue(prompt.contains("list_meetings"))
        XCTAssertTrue(prompt.contains("search_meetings"))
        XCTAssertTrue(prompt.contains("get_meeting"))
        XCTAssertTrue(prompt.contains("When did I last talk about hiring?"))
    }

    func testLibraryPromptFallsBackOnEmptyQuestion() {
        let prompt = ClaudeDesktopPrompt.library(question: "")
        XCTAssertTrue(prompt.contains("talking about"))
    }
}
