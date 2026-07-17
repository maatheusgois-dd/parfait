import XCTest
@testable import Nutola

final class ClaudeCLITests: XCTestCase {
    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func testDefaultsDisableAllBuiltinTools() {
        let args = ClaudeCLI.buildArgs(prompt: "hello")
        XCTAssertEqual(Array(args.prefix(2)), ["-p", "hello"])
        XCTAssertEqual(value(after: "--output-format", in: args), "json")
        XCTAssertEqual(value(after: "--model", in: args), "sonnet")
        XCTAssertEqual(value(after: "--max-turns", in: args), "1")
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertEqual(value(after: "--tools", in: args), "")
        XCTAssertFalse(args.contains("--system-prompt"))
        XCTAssertFalse(args.contains("--resume"))
        XCTAssertFalse(args.contains("--allowedTools"))
        XCTAssertFalse(args.contains("--mcp-config"))
    }

    func testSystemPromptResumeModelMaxTurns() {
        let args = ClaudeCLI.buildArgs(
            prompt: "p", systemPrompt: "be brief", model: "haiku",
            resume: "abc-123", maxTurns: 3)
        XCTAssertEqual(value(after: "--system-prompt", in: args), "be brief")
        XCTAssertEqual(value(after: "--resume", in: args), "abc-123")
        XCTAssertEqual(value(after: "--model", in: args), "haiku")
        XCTAssertEqual(value(after: "--max-turns", in: args), "3")
    }

    func testBuiltinsStayDisabledWithMCPAndAllowedTools() {
        // The security-relevant invariant: enabling MCP tools must NOT re-enable
        // the built-in tool set (Bash, Write, …).
        let args = ClaudeCLI.buildArgs(
            prompt: "p", allowedTools: ["mcp__nutola__search_meetings"], mcpConfigJSON: "{}")
        XCTAssertEqual(value(after: "--tools", in: args), "")
        XCTAssertEqual(value(after: "--allowedTools", in: args), "mcp__nutola__search_meetings")
        XCTAssertEqual(value(after: "--mcp-config", in: args), "{}")
        XCTAssertTrue(args.contains("--strict-mcp-config"))
    }

    func testExplicitBuiltinToolsAreScoped() {
        let args = ClaudeCLI.buildArgs(
            prompt: "p",
            builtinTools: ["Read"],
            allowedTools: ["Read(//tmp/x.html)"])
        XCTAssertEqual(value(after: "--tools", in: args), "Read")
        XCTAssertEqual(value(after: "--allowedTools", in: args), "Read(//tmp/x.html)")
    }

    func testAllowedToolsJoined() {
        let args = ClaudeCLI.buildArgs(prompt: "p", allowedTools: ["Read", "Bash(git *)"])
        XCTAssertEqual(value(after: "--allowedTools", in: args), "Read,Bash(git *)")
    }
}
