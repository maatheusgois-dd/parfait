import Foundation

/// Routes Ask AI actions to the user's chosen assistant.
enum AIAsk {
    static var provider: AIProvider { AppSettings.preferredAIProvider }

    static var isAvailable: Bool {
        switch provider {
        case .apple: false
        case .claude: ClaudeDesktop.isInstalled
        case .codex: CodexApp.isInstalled
        }
    }

    static var displayName: String { provider.displayName }

    @discardableResult
    static func open(prompt: String) -> Bool {
        switch provider {
        case .apple: false
        case .claude: ClaudeDesktop.openNewChat(prompt: prompt)
        case .codex: CodexApp.openNewThread(prompt: prompt)
        }
    }

    @discardableResult
    static func openMeeting(id: UUID, title: String, question: String) -> Bool {
        switch provider {
        case .apple: false
        case .claude:
            ClaudeDesktop.openNewChat(
                prompt: ClaudeDesktopPrompt.meeting(id: id, title: title, question: question))
        case .codex:
            CodexApp.openNewThread(prompt: CodexPrompt.meeting(id: id, title: title, question: question))
        }
    }

    @discardableResult
    static func openLibrary(question: String) -> Bool {
        switch provider {
        case .apple: false
        case .claude: ClaudeDesktop.openNewChat(prompt: ClaudeDesktopPrompt.library(question: question))
        case .codex: CodexApp.openNewThread(prompt: CodexPrompt.library(question: question))
        }
    }

    @discardableResult
    static func openLive(question: String = "") -> Bool {
        switch provider {
        case .apple: false
        case .claude: ClaudeDesktop.openNewChat(prompt: ClaudeDesktopPrompt.live(question: question))
        case .codex: CodexApp.openNewThread(prompt: CodexPrompt.live(question: question))
        }
    }
}
