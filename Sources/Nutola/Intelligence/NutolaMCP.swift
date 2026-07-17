import Foundation

/// Inline MCP config for Claude Code CLI runs that need the Nutola meeting archive.
enum NutolaMCP {
    static var binaryPath: String {
        Bundle.main.executablePath ?? "/Applications/Nutola.app/Contents/MacOS/Nutola"
    }

    static let allowedTools = [
        "mcp__nutola__list_meetings",
        "mcp__nutola__search_meetings",
        "mcp__nutola__get_meeting",
        "mcp__nutola__get_transcript",
        "mcp__nutola__get_live_transcript",
        "mcp__nutola__list_templates",
    ]

    static var configJSON: String {
        """
        {"mcpServers":{"nutola":{"command":"\(binaryPath)","args":["--mcp"]}}}
        """
    }
}
