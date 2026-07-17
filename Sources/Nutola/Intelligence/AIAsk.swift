import Foundation

/// Routes Ask AI actions to the user's chosen assistant.
enum AIAsk {
    static var provider: AIProvider { AppSettings.preferredAIProvider }
    static var deliveryMode: AskDeliveryMode { AppSettings.askDeliveryMode }

    static var isAvailable: Bool {
        switch provider {
        case .apple: return AppleSummarizer.isAvailable
        case .claude, .codex: return isAvailable(for: deliveryMode)
        }
    }

    static func isAvailable(for mode: AskDeliveryMode) -> Bool {
        isAvailable(for: mode, provider: provider)
    }

    static func isAvailable(for mode: AskDeliveryMode, provider: AIProvider) -> Bool {
        switch provider {
        case .apple:
            return mode == .cli && AppleSummarizer.isAvailable
        case .claude:
            switch mode {
            case .app: return ClaudeDesktop.isInstalled
            case .cli: return ClaudeCLI.isInstalled && ClaudeCLI.isLoggedIn()
            }
        case .codex:
            switch mode {
            case .app: return CodexApp.isInstalled
            case .cli: return CodexCLI.isReady
            }
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

    static func cancel() {
        switch provider {
        case .apple: break
        case .claude: ClaudeCLI.cancelRunning()
        case .codex: CodexCLI.cancelRunning()
        }
    }

    static func answer(prompt: String, onDelta: (@Sendable (String) -> Void)? = nil) async throws -> String {
        NutolaConsoleLog.ask("answer via \(provider.displayName) mode=\(deliveryMode.displayName) prompt=\(prompt.count) chars")
        let systemPrompt =
            "You are Nutola. Meeting data is appended below — answer immediately from it. "
            + "Never say you will look up, fetch, or call tools. Be concise."
        switch provider {
        case .apple:
            let enriched = AskContextBuilder.enrichForAsk(prompt, limits: .onDevice)
            return try await AppleSummarizer.answer(prompt: enriched, onDelta: onDelta)
        case .claude:
            let enriched = AskContextBuilder.enrichForCLI(prompt)
            if let onDelta {
                let result = try await ClaudeCLI.stream(
                    prompt: enriched,
                    systemPrompt: systemPrompt,
                    onDelta: onDelta
                )
                return result.text
            }
            let result = try await ClaudeCLI.run(
                prompt: enriched,
                systemPrompt: systemPrompt
            )
            return result.text
        case .codex:
            let enriched = AskContextBuilder.enrichForCLI(prompt)
            let result = try await CodexCLI.run(
                prompt: enriched,
                systemPrompt: systemPrompt
            )
            return result.text
        }
    }

    @discardableResult
    static func openMeeting(id: UUID, title: String, question: String) -> Bool {
        NutolaConsoleLog.ask("openMeeting \"\(title)\" via \(provider.displayName)")
        switch provider {
        case .apple: return false
        case .claude:
            return ClaudeDesktop.openNewChat(
                prompt: ClaudeDesktopPrompt.meeting(id: id, title: title, question: question))
        case .codex:
            return CodexApp.openNewThread(prompt: CodexPrompt.meeting(id: id, title: title, question: question))
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

enum AIAskError: LocalizedError {
    case unsupportedProvider

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            "Pick an assistant to ask about meetings."
        }
    }
}
