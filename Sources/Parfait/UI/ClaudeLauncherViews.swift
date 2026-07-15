import SwiftUI

struct MeetingLauncherView: View {
    let meeting: Meeting

    var body: some View {
        AILauncherView(
            title: "Ask about this meeting",
            subtitle: "Ask about this meeting through the parfait connector.",
            suggestions: [],
            promptBuilder: { question in
                switch AppSettings.preferredAIProvider {
                case .apple:
                    ""
                case .claude:
                    ClaudeDesktopPrompt.meeting(
                        id: meeting.id, title: meeting.title, question: question)
                case .codex:
                    CodexPrompt.meeting(
                        id: meeting.id, title: meeting.title, question: question)
                }
            }
        )
    }
}

struct LibraryLauncherView: View {
    var body: some View {
        AILauncherView(
            title: "Ask across every meeting",
            subtitle: "Ask anything across your whole meeting library, through the parfait connector.",
            suggestions: [],
            promptBuilder: { question in
                switch AppSettings.preferredAIProvider {
                case .apple:
                    ""
                case .claude: ClaudeDesktopPrompt.library(question: question)
                case .codex: CodexPrompt.library(question: question)
                }
            }
        )
        .navigationTitle("Ask your meetings")
    }
}

/// Shared launcher: compose field + Ask AI button for the user's chosen assistant.
struct AILauncherView: View {
    let title: String
    let subtitle: String
    let suggestions: [String]
    let promptBuilder: (String) -> String

    @AppStorage(SettingsKey.preferredAIProvider) private var preferredAIProvider: AIProvider = .apple
    @State private var input = ""
    @State private var available = AIAsk.isAvailable
    @State private var launchFailed = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.parfait(17, .semibold))
                Text(subtitle).font(.parfait(12)).foregroundStyle(.secondary)
            }

            if !suggestions.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button { launch(suggestion) } label: {
                            SuggestionChip(text: suggestion)
                        }
                        .buttonStyle(.plain)
                        .disabled(!available)
                        .opacity(available ? 1 : 0.4)
                    }
                }
            }

            composeBar

            if available {
                Text("Tip: once the parfait connector is set up, you can open \(preferredAIProvider.displayName) and ask about your meetings anytime — you don't have to start here. Use $parfait to attach the connector.")
                    .font(.parfait(11))
                    .foregroundStyle(.secondary)
            } else if preferredAIProvider == .apple {
                Text("Apple Intelligence handles summaries on-device. Pick Claude or Codex in Settings → Intelligence to ask about your meetings in chat.")
                    .font(.parfait(11))
                    .foregroundStyle(.secondary)
            }

            if launchFailed {
                Label("Couldn't open \(preferredAIProvider.displayName).", systemImage: "exclamationmark.triangle")
                    .font(.parfait(11))
                    .foregroundStyle(.orange)
            }

            if !available {
                unavailableNotice
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface(scheme))
        .id(preferredAIProvider)
        .onAppear { available = AIAsk.isAvailable }
        .onChange(of: preferredAIProvider) { available = AIAsk.isAvailable }
    }

    private var composeBar: some View {
        HStack(spacing: 10) {
            TextField("Ask anything…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.parfait(13))
                .lineLimit(1...4)
                .disabled(!available)
                .onSubmit(launchTyped)
                .padding(12)
                .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10))
            Button(action: launchTyped) {
                Label("Ask AI", systemImage: "arrow.up.forward.app")
                    .font(.parfait(13, .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.raspberry)
            .disabled(!available || input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private var unavailableNotice: some View {
        switch preferredAIProvider {
        case .apple:
            VStack(alignment: .leading, spacing: 6) {
                Label("Chat needs Claude or Codex", systemImage: "info.circle")
                    .font(.parfait(12, .semibold))
                    .foregroundStyle(.secondary)
                Text("Summaries already use Apple Intelligence on this Mac. Switch assistant in Settings → Intelligence to ask about meetings.")
                    .font(.parfait(11))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        case .claude:
            VStack(alignment: .leading, spacing: 6) {
                Label("Claude Desktop isn't installed", systemImage: "exclamationmark.triangle")
                    .font(.parfait(12, .semibold))
                    .foregroundStyle(.orange)
                HStack(spacing: 4) {
                    Link("Get Claude Desktop", destination: URL(string: "https://claude.ai/download")!)
                    Text("— then add the parfait connector in Settings.")
                        .foregroundStyle(.secondary)
                }
                .font(.parfait(11))
            }
            .padding(12)
            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        case .codex:
            VStack(alignment: .leading, spacing: 6) {
                Label("Codex isn't installed", systemImage: "exclamationmark.triangle")
                    .font(.parfait(12, .semibold))
                    .foregroundStyle(.orange)
                HStack(spacing: 4) {
                    Link("Get Codex", destination: URL(string: "https://chatgpt.com/codex")!)
                    Text("— then add the parfait connector in Settings.")
                        .foregroundStyle(.secondary)
                }
                .font(.parfait(11))
            }
            .padding(12)
            .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func launch(_ question: String) {
        launchFailed = !AIAsk.open(prompt: promptBuilder(question))
        if !launchFailed { input = "" }
    }

    private func launchTyped() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        launch(text)
    }
}

private struct SuggestionChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.parfait(12, .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.honey.opacity(0.16), in: Capsule())
            .foregroundStyle(.primary)
    }
}
