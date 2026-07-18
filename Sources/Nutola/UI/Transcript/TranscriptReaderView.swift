import SwiftUI

struct TranscriptReaderView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.nutolaActionColor) private var actionColor

    let meeting: Meeting
    let segments: [TranscriptSegment]
    @Binding var draft: String?
    var continueActionTitle: String?
    var continueAction: (() -> Void)?

    @State private var renaming: Speaker?
    @State private var newName = ""
    @State private var searchText = ""
    @State private var searchMatchCount = 0
    @State private var currentMatchIndex: Int? = nil
    /// #17 — focus state for the search field, used to highlight the field
    /// with a colored ring/background while the user is typing in it.
    @FocusState private var searchFocused: Bool
    /// Pin state lives in a shared store; each turn card observes it via
    /// `PinToggleButton` so toggles re-render without a manual version bump.
    private var pins: PinnedSegmentsStore { .shared }

    private var turns: [TranscriptTurn] {
        TranscriptTurnBuilder.turns(from: segments)
    }

    private var filteredTurns: [TranscriptTurn] {
        TranscriptTurnBuilder.filter(turns: turns, by: searchText)
    }

    /// Per-speaker talk-time breakdown for the Transcript tab header chip.
    private var talkTimeStats: [SpeakerStats] {
        TalkTimeStats.compute(segments: segments, speakers: meeting.speakers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar

            if draft == nil, !segments.isEmpty {
                searchBar
            }

            if draft != nil {
                editView
            } else if segments.isEmpty {
                EmptyStateView(
                    title: "No transcript",
                    message: meeting.state == .processing
                        ? "Transcription is still running."
                        : (MeetingNotice.presentation(for: meeting.notice)?.message
                            ?? "Nothing was transcribed for this meeting."),
                    actionTitle: continueActionTitle,
                    action: continueAction)
            } else {
                turnsScroll
            }
        }
        .safeAreaInset(edge: .bottom) {
            if continueActionTitle != nil, let action = continueAction {
                resumeBar(action: action)
            }
        }
        .sheet(item: $renaming) { speaker in
            renameSheet(speaker)
        }
        .background {
            Button("Next match") { goToNextMatch() }
                .keyboardShortcut("g", modifiers: .command)
                .hidden()
            Button("Previous match") { goToPreviousMatch() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .hidden()
        }
    }

    private var toolbar: some View {
        HStack {
            if !segments.isEmpty {
                Text(statsLabel)
                    .font(.nutola(11))
                    .foregroundStyle(Theme.tertiary(scheme))
                TalkTimeStatsBar(stats: talkTimeStats)
            }
            Spacer()
            if draft != nil {
                Button("Cancel") { draft = nil }
                Button("Save") { saveEdits() }
                    .buttonStyle(.borderedProminent)
                    .tint(actionColor)
            } else {
                Button {
                    draft = TranscriptFormatter.plainText(segments, speakers: meeting.speakers)
                } label: {
                    Label("Edit as text", systemImage: "pencil")
                }
                .disabled(segments.isEmpty)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var statsLabel: String {
        let duration = segments.map(\.end).max() ?? 0
        let mins = max(1, Int((duration / 60).rounded()))
        return "\(segments.count) segments · \(mins) min"
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(searchFocused ? actionColor : Theme.tertiary(scheme))
                .font(.system(size: 12))
            TextField("Search transcript", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .accessibilityLabel("Search transcript")
                .onChange(of: searchText) { _, newValue in
                    let matches = TranscriptTurnBuilder.filter(turns: turns, by: newValue)
                    searchMatchCount = matches.count
                    currentMatchIndex = matches.isEmpty ? nil : 0
                }
            if !searchText.isEmpty {
                Text(currentMatchLabel)
                    .font(.nutola(11))
                    .foregroundStyle(Theme.tertiary(scheme))
                Button { goToPreviousMatch() } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.tertiary(scheme))
                }
                .buttonStyle(.plain)
                .help("Previous match (⌘⇧G)")
                Button { goToNextMatch() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.tertiary(scheme))
                }
                .buttonStyle(.plain)
                .help("Next match (⌘G)")
                Button {
                    searchText = ""
                    searchMatchCount = 0
                    currentMatchIndex = nil
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.tertiary(scheme))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // #17 — tint the field background and add a colored focus ring so the
        // active search field is visually distinct from the surrounding card.
        .background(
            (searchFocused ? actionColor.opacity(0.08) : Theme.card(scheme)),
            in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    searchFocused ? actionColor.opacity(0.45) : Color.primary.opacity(0.06),
                    lineWidth: searchFocused ? 1.5 : 1)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private var editView: some View {
        TextEditor(text: Binding(get: { draft ?? "" }, set: { draft = $0 }))
            .font(.system(size: 13, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(12)
            .cardStyle()
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
    }

    private var turnsScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(filteredTurns.enumerated()), id: \.element.id) { idx, turn in
                        turnRow(turn, isCurrentMatch: currentMatchIndex == idx && !searchText.isEmpty)
                    }
                }
                .frame(maxWidth: 660, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: currentMatchIndex) { _, idx in
                guard let idx, idx < filteredTurns.count else { return }
                withAnimation { proxy.scrollTo(filteredTurns[idx].id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func turnRow(_ turn: TranscriptTurn, isCurrentMatch: Bool) -> some View {
        TranscriptTurnCard(
            turn: turn,
            speakerName: name(for: turn.speakerID),
            speakerColor: TranscriptTurnBuilder.speakerColor(
                speakerID: turn.speakerID,
                speakers: meeting.speakers,
                turns: turns,
                scheme: scheme),
            onRename: {
                newName = name(for: turn.speakerID)
                renaming = meeting.speakers.first { $0.id == turn.speakerID }
                    ?? Speaker(id: turn.speakerID, name: name(for: turn.speakerID))
            })
        .id(turn.id)
        .overlay(alignment: .topTrailing) {
            pinButton(for: turn)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrentMatch ? actionColor.opacity(0.12) : Color.clear))
        .animation(.easeOut(duration: 0.15), value: currentMatchIndex)
    }

    @ViewBuilder
    private func resumeBar(action: @escaping () -> Void) -> some View {
        HStack {
            Button(action: action) {
                Label("Resume", systemImage: "mic.fill")
                    .font(.nutola(12, .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(actionColor)
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    /// Bookmark toggle pinned to each turn card's top-trailing corner.
    /// A dedicated `@ObservedObject` view so it re-renders the instant the
    /// shared store publishes a change — no manual version counter needed.
    private func pinButton(for turn: TranscriptTurn) -> some View {
        PinToggleButton(
            store: pins,
            meetingID: meeting.id,
            turn: turn,
            speakerName: name(for: turn.speakerID),
            actionColor: actionColor,
            tertiaryColor: Theme.tertiary(scheme))
    }

    private func name(for speakerID: String) -> String {
        meeting.speakers.first { $0.id == speakerID }?.name ?? speakerID
    }

    private var currentMatchLabel: String {
        guard searchMatchCount > 0 else { return "0 matches" }
        let displayed = (currentMatchIndex ?? 0) + 1
        return "\(displayed) of \(searchMatchCount)"
    }

    private func goToNextMatch() {
        guard searchMatchCount > 0 else { return }
        if let idx = currentMatchIndex, idx + 1 < searchMatchCount {
            currentMatchIndex = idx + 1
        } else {
            currentMatchIndex = 0
        }
    }

    private func goToPreviousMatch() {
        guard searchMatchCount > 0 else { return }
        if let idx = currentMatchIndex, idx > 0 {
            currentMatchIndex = idx - 1
        } else {
            currentMatchIndex = searchMatchCount - 1
        }
    }

    private func renameSheet(_ speaker: Speaker) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(speaker.name)")
                .font(.nutola(15, .semibold))
            TextField("Name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { commitRename(speaker) }
            if !meeting.attendees.isEmpty {
                Text("From the calendar invite:")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(meeting.attendees, id: \.self) { attendee in
                        Button { newName = attendee } label: { Chip(text: attendee) }
                            .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { renaming = nil }
                Button("Rename") { commitRename(speaker) }
                    .buttonStyle(.borderedProminent)
                    .tint(actionColor)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func commitRename(_ speaker: Speaker) {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        app.store.renameSpeaker(meetingID: meeting.id, speakerID: speaker.id, to: n)
        renaming = nil
    }

    private func saveEdits() {
        guard let text = draft else { return }
        let (parsed, speakers) = TranscriptFormatter.parseEdited(
            text, originalSegments: segments, speakers: meeting.speakers)
        guard !parsed.isEmpty else { draft = nil; return }
        app.store.saveTranscript(parsed, for: meeting.id)
        if var fresh = app.store.meeting(id: meeting.id) {
            fresh.speakers = speakers
            app.store.upsert(fresh)
        }
        draft = nil
    }
}


/// The bookmark toggle on each transcript turn card.
///
/// Observes the shared `PinnedSegmentsStore` directly so the icon flips the
/// moment a pin is added or removed — no parent-view rebuild required. Kept
/// as a tiny leaf view so the rest of `TranscriptReaderView` doesn't have to
/// observe the store (which would re-render every turn on every toggle).
private struct PinToggleButton: View {
    @ObservedObject var store: PinnedSegmentsStore
    let meetingID: UUID
    let turn: TranscriptTurn
    let speakerName: String
    let actionColor: Color
    let tertiaryColor: Color

    var body: some View {
        let pinned = store.isPinned(meetingID: meetingID, turnID: turn.id)
        Button {
            store.toggle(
                meetingID: meetingID, turn: turn, speakerName: speakerName)
        } label: {
            Image(systemName: pinned ? "bookmark.fill" : "bookmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(pinned ? actionColor : tertiaryColor)
        }
        .buttonStyle(.plain)
        .help(pinned ? "Unpin this turn" : "Pin this turn")
        .accessibilityLabel(pinned ? "Unpin turn" : "Pin turn")
    }
}