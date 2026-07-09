import SwiftUI

struct MeetingLauncherView: View {
    let meeting: Meeting

    var body: some View {
        ClaudeLauncherView(
            title: "Ask about this meeting",
            subtitle: "Opens Claude Desktop with this meeting loaded through the parfait connector.",
            suggestions: [
                "What did we decide?",
                "List every action item with owners",
                "What did \(firstOtherSpeaker) say about timelines?",
            ],
            promptBuilder: { question in
                ClaudeDesktopPrompt.meeting(
                    id: meeting.id, title: meeting.title, date: meeting.createdAt, question: question)
            }
        )
    }

    private var firstOtherSpeaker: String {
        meeting.speakers.first { !$0.isMe }?.name ?? "Speaker 1"
    }
}

struct LibraryLauncherView: View {
    var body: some View {
        ClaudeLauncherView(
            title: "Ask across every meeting",
            subtitle: "Claude searches your local meeting library through the parfait connector.",
            suggestions: [
                "When did I last talk about hiring?",
                "Summarize everything we've said about the Q3 launch",
            ],
            promptBuilder: { question in ClaudeDesktopPrompt.library(question: question) }
        )
        .navigationTitle("Ask your meetings")
    }
}

/// Shared launcher UI: suggestion chips + compose field + "Open in Claude"
/// button. Claude Desktop does the actual conversing now — this view's only
/// job is turning intent into a good deep-link prompt.
struct ClaudeLauncherView: View {
    let title: String
    let subtitle: String
    let suggestions: [String]
    let promptBuilder: (String) -> String

    @State private var input = ""
    @State private var installed = ClaudeDesktop.isInstalled
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
                        .disabled(!installed)
                        .opacity(installed ? 1 : 0.4)
                    }
                }
            }

            composeBar

            if launchFailed {
                Label("Couldn't open Claude Desktop.", systemImage: "exclamationmark.triangle")
                    .font(.parfait(11))
                    .foregroundStyle(.orange)
            }

            if !installed {
                unavailableNotice
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface(scheme))
        .onAppear { installed = ClaudeDesktop.isInstalled }
    }

    private var composeBar: some View {
        HStack(spacing: 10) {
            TextField("Ask anything…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.parfait(13))
                .lineLimit(1...4)
                .disabled(!installed)
                .onSubmit(launchTyped)
                .padding(12)
                .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 10))
            Button(action: launchTyped) {
                Label("Open in Claude", systemImage: "arrow.up.forward.app")
                    .font(.parfait(13, .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.raspberry)
            .disabled(!installed || input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var unavailableNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Claude Desktop isn't installed", systemImage: "exclamationmark.triangle")
                .font(.parfait(12, .semibold))
                .foregroundStyle(.orange)
            HStack(spacing: 4) {
                Link("Get Claude Desktop", destination: URL(string: "https://claude.ai/download")!)
                Text("— then add the parfait connector in Settings → Connect Claude.")
                    .foregroundStyle(.secondary)
            }
            .font(.parfait(11))
        }
        .padding(12)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }

    private func launch(_ question: String) {
        launchFailed = !ClaudeDesktop.openNewChat(prompt: promptBuilder(question))
        if !launchFailed { input = "" }
    }

    private func launchTyped() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        launch(text)
    }
}

/// Like Chip, but sized for full sentences instead of short labels (attendee
/// names, "Optional") — Chip's fixed 160pt width + tail-truncation would clip
/// suggestions like "Summarize everything we've said about the Q3 launch".
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
