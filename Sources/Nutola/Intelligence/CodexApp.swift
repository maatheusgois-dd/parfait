import AppKit
import Foundation

/// Deep-link launcher for the Codex desktop app.
enum CodexApp {
    static let maxPromptLength = 4000

    static var isInstalled: Bool {
        guard let probe = URL(string: "codex://") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
    }

    static func newThreadURL(prompt: String) -> URL? {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/new"
        components.queryItems = [
            URLQueryItem(name: "prompt", value: String(prompt.prefix(maxPromptLength))),
        ]
        return components.url
    }

    @discardableResult
    static func openNewThread(prompt: String) -> Bool {
        guard let url = newThreadURL(prompt: prompt) else { return false }
        return NSWorkspace.shared.open(url)
    }
}

enum CodexPrompt {
    private static let defaultMeetingQuestion =
        "Give me a quick overview of this meeting — key decisions and action items."
    private static let defaultLibraryQuestion =
        "What have I been talking about across my recent meetings?"

    static func meeting(id: UUID, title: String, question: String) -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Answer a question about my Nutola meeting "\(title)" (id: \(id.uuidString)) using the $nutola connector.

        \(q.isEmpty ? defaultMeetingQuestion : q)
        """
    }

    static func library(question: String) -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Answer using my Nutola meetings via the $nutola connector:

        \(q.isEmpty ? defaultLibraryQuestion : q)
        """
    }

    static func live(question: String) -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let ask = q.isEmpty ? "What's being discussed, and is there anything I should add or ask?" : q
        return "I'm in a Nutola meeting happening right now — use $nutola for the live transcript. \(ask)"
    }
}

enum CodexSetup {
    static var isAvailable: Bool { CodexCLI.isReady }

    @discardableResult
    static func addMCPServer(binary: String) -> Bool {
        CodexApp.openNewThread(prompt: """
        Connect Nutola to Codex as an MCP server so you can read my meeting library. Run:

        codex mcp add nutola -- "\(binary)" --mcp

        Then confirm with `codex mcp list`. Remind me to use $nutola (not @) to access meetings.
        """)
    }
}
