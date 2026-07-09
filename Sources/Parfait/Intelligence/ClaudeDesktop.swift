import AppKit
import Foundation

/// Deep-link launcher for Claude Desktop, replacing the in-app chat engines.
/// support.claude.com: claude://claude.ai/new?q=<url-encoded prompt> opens a
/// NEW chat with the prompt PRE-FILLED — the user still reviews and hits send.
/// There is no parameter to enable a connector, so the prompt text itself must
/// name "parfait" and its tools (see ClaudeDesktopPrompt below).
enum ClaudeDesktop {
    /// The q value is truncated around 14,000 characters server-side. We never
    /// get close in practice — Claude fetches meeting content itself via MCP,
    /// so the prompt only carries instructions + the user's typed question —
    /// but a generous cap keeps a runaway typed question from breaking the link.
    static let maxPromptLength = 4000

    /// NSWorkspace resolving the scheme handler is a fast Launch Services
    /// lookup (no shell-out), unlike ClaudeCLI.isInstalled's login-shell
    /// fallback — safe to call directly from a view body.
    static var isInstalled: Bool {
        guard let probe = URL(string: "claude://") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
    }

    /// Pure — no side effects — so it's unit-testable without NSWorkspace.
    static func newChatURL(prompt: String) -> URL? {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "claude.ai"
        components.path = "/new"
        components.queryItems = [URLQueryItem(name: "q", value: String(prompt.prefix(maxPromptLength)))]
        // URLComponents encodes & and = in the value but leaves a literal + (a Foundation
        // quirk); a parser that form-decodes would read + as a space, so encode it too.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// Side-effecting half of the pair above.
    @discardableResult
    static func openNewChat(prompt: String) -> Bool {
        guard let url = newChatURL(prompt: prompt) else { return false }
        return NSWorkspace.shared.open(url)
    }
}

/// Builds the instruction text that steers Claude Desktop to Parfait's own
/// "parfait" MCP connector — the deep link has no param for this, so the
/// prompt has to say it explicitly, by name, every time.
enum ClaudeDesktopPrompt {
    private static let defaultMeetingQuestion =
        "Give me a quick overview of this meeting — key decisions and action items."
    private static let defaultLibraryQuestion =
        "What have I been talking about across my recent meetings?"

    static func meeting(id: UUID, title: String, date: Date, question: String) -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let when = date.formatted(date: .abbreviated, time: .shortened)
        return """
        Use the "parfait" connector (MCP tools get_meeting and get_transcript) to answer a \
        question about one specific meeting recorded with Parfait.

        Meeting: "\(title)" — \(when)
        Meeting ID: \(id.uuidString)

        Call get_meeting with id "\(id.uuidString)" for the summary and metadata. If you need \
        direct quotes, timestamps, or something the summary doesn't cover, also call \
        get_transcript with the same id. Answer only from what those tools return.

        Question: \(q.isEmpty ? defaultMeetingQuestion : q)
        """
    }

    static func library(question: String) -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Use the "parfait" connector (MCP tools list_meetings, search_meetings, and get_meeting) \
        to answer a question across every meeting recorded with Parfait.

        Search or list meetings as needed, then call get_meeting for the full summary of any \
        meeting that looks relevant. Name the specific meeting(s) and date(s) you found things \
        in. If nothing matches, say so plainly — don't guess.

        Question: \(q.isEmpty ? defaultLibraryQuestion : q)
        """
    }
}
