import SwiftUI

struct MeetingChatView: View {
    let meeting: Meeting
    @StateObject private var chat: MeetingChat

    /// The enclosing detail view is keyed by meeting id (.id(id)), so this
    /// StateObject — and the chat history — lives exactly as long as one meeting
    /// is on screen.
    @MainActor
    init(meeting: Meeting, store: MeetingStore) {
        self.meeting = meeting
        _chat = StateObject(wrappedValue: MeetingChat(meeting: meeting, store: store))
    }

    var body: some View {
        ChatTranscriptView(
            messages: chat.messages,
            isThinking: chat.isThinking,
            errorText: chat.errorText,
            placeholderTitle: "Ask about this meeting",
            placeholderMessage: "\u{201C}What did we decide?\u{201D} · \u{201C}List every action item with owners\u{201D} · \u{201C}What did \(firstOtherSpeaker) say about timelines?\u{201D}",
            canSend: chat.canChat,
            unavailableMessage: "Enable Apple Intelligence or install Claude Code to chat with meetings."
        ) { text in
            await chat.send(text)
        }
    }

    private var firstOtherSpeaker: String {
        meeting.speakers.first { !$0.isMe }?.name ?? "Speaker 1"
    }
}

struct LibraryChatView: View {
    @StateObject private var chat = LibraryChat()

    var body: some View {
        ChatTranscriptView(
            messages: chat.messages,
            isThinking: chat.isThinking,
            errorText: chat.errorText,
            placeholderTitle: "Ask across every meeting",
            placeholderMessage: "Claude searches your local meeting library through Parfait's MCP server. \u{201C}When did I last talk about hiring?\u{201D} · \u{201C}Summarize everything we've said about the Q3 launch\u{201D}",
            canSend: chat.isAvailable,
            unavailableMessage: "This needs Claude Code (your own account). Install it from claude.com/claude-code, run `claude` once to log in, then come back."
        ) { text in
            await chat.send(text)
        }
        .navigationTitle("Ask your meetings")
    }
}

/// Shared chat UI: message list + input bar.
struct ChatTranscriptView: View {
    let messages: [ChatMessage]
    let isThinking: Bool
    let errorText: String?
    let placeholderTitle: String
    let placeholderMessage: String
    let canSend: Bool
    let unavailableMessage: String
    let onSend: (String) async -> Void

    @State private var input = ""
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            if messages.isEmpty {
                EmptyStateView(title: placeholderTitle, message: placeholderMessage)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                            if isThinking {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Thinking…")
                                        .font(.parfait(12))
                                        .foregroundStyle(.secondary)
                                }
                                .id("thinking")
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: 720, alignment: .leading)
                    }
                    .onChange(of: messages.count) {
                        withAnimation {
                            if isThinking {
                                proxy.scrollTo("thinking", anchor: .bottom)
                            } else if let last = messages.last?.id {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .font(.parfait(11))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            inputBar
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(canSend ? "Ask anything…" : unavailableMessage, text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.parfait(13))
                .lineLimit(1...4)
                .focused($focused)
                .disabled(!canSend)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(canSend && !input.isEmpty ? Theme.raspberry : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!canSend || input.isEmpty || isThinking)
        }
        .padding(12)
        .background(Theme.card(scheme))
    }

    private func send() {
        let text = input
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !isThinking else { return }
        input = ""
        Task { await onSend(text) }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            if message.role == .user {
                Text(message.text)
                    .font(.parfait(13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.blueberry.opacity(scheme == .dark ? 0.35 : 0.12),
                                in: RoundedRectangle(cornerRadius: 12))
            } else {
                MarkdownText(markdown: message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: 12))
                ProviderBadge(provider: message.provider)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}
