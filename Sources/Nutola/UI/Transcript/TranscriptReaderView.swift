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
    /// Bookmark markers dropped during recording (⌃⌥B / "Hey Nutola, mark
    /// this"). A shared per-meeting store; each turn card observes it via
    /// `MarkerBadgeView` so badges flip without a manual version bump.
    private var markerStore: TranscriptMarkerStore { .shared }
    /// Drives the `turnsScroll` proxy to scroll to a turn when a marker is
    /// clicked while viewing (not recording). Set to a turn id; cleared after
    /// the scroll lands so re-clicking the same marker re-scrolls.
    @State private var markerScrollTarget: String?
    /// Auto-outline: chapters detected from topic shifts. The outline bar is
    /// shown only when there is more than one chapter.
    @State private var activeChapterIndex: Int? = nil
    /// Drives `turnsScroll` to jump to a chapter's opening turn when its
    /// outline button is clicked. Set to a chapter index; cleared after the
    /// scroll lands so re-clicking re-scrolls.
    @State private var pendingChapterScroll: Int?

    private var turns: [TranscriptTurn] {
        TranscriptTurnBuilder.turns(from: segments)
    }

    private var filteredTurns: [TranscriptTurn] {
        TranscriptTurnBuilder.filter(turns: turns, by: searchText)
    }
    /// Auto-outline chapters for the transcript. Built from the full turn
    /// list (not the filtered one) so chapter boundaries stay stable while
    /// searching; the outline bar only renders when there is more than one.
    private var chapters: [Chapter] {
        TranscriptChapterizer.chapterize(turns: turns)
    }

    /// Per-speaker talk-time breakdown for the Transcript tab header chip.
    private var talkTimeStats: [SpeakerStats] {
        TalkTimeStats.compute(segments: segments, speakers: meeting.speakers)
    }

    /// Per-segment sentiment labels for the transcript. Computed once per
    /// view refresh and reused by `sentiment(for:)` to attach a small
    /// indicator to each turn card. Stays free of SwiftUI types so the
    /// analyzer remains unit-testable without AppKit.
    private var sentiments: [SpeakerSentiment] {
        SentimentAnalyzer.analyze(segments: segments, speakers: meeting.speakers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar

            if draft == nil, !segments.isEmpty {
                searchBar
                if chapters.count > 1 {
                    chapterOutlineBar
                }
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
            // ⌃⌥B — drop a bookmark at the current recording timestamp while
            // this meeting is being recorded. When viewing (not recording) the
            // same shortcut scrolls to the next marker instead, so the key is
            // useful in both states.
            Button("Add bookmark") { addBookmarkOrJumpToNext() }
                .keyboardShortcut("b", modifiers: [.control, .option])
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

    /// Auto-outline: a horizontal bar of chapter buttons at the top of the
    /// transcript. Each button scrolls to its chapter's opening turn; the
    /// active (last-clicked) chapter is highlighted with the action color.
    /// Only rendered when there is more than one chapter — a single-chapter
    /// transcript needs no outline.
    private var chapterOutlineBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                    Button {
                        pendingChapterScroll = index
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(chapter.title)
                                .font(.nutola(11, .semibold))
                                .lineLimit(1)
                            Text(MeetingArchive.timestamp(chapter.startTime))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Theme.tertiary(scheme))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(maxWidth: 180, alignment: .leading)
                        .background(
                            (activeChapterIndex == index
                                ? actionColor.opacity(0.14)
                                : Theme.card(scheme)),
                            in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    activeChapterIndex == index
                                        ? actionColor.opacity(0.45)
                                        : Color.primary.opacity(0.06),
                                    lineWidth: activeChapterIndex == index ? 1.5 : 1)
                        }
                        .foregroundStyle(
                            activeChapterIndex == index
                                ? actionColor
                                : Theme.secondary(scheme))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Chapter \(index + 1): \(chapter.title) at \(MeetingArchive.timestamp(chapter.startTime))")
                    .help("\(chapter.title) · \(MeetingArchive.timestamp(chapter.startTime))")
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
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
            .onChange(of: markerScrollTarget) { _, target in
                // Clicking a marker while viewing scrolls to the turn it
                // bookmarks. Cleared after landing so the same marker can be
                // clicked again to re-scroll.
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .center) }
                markerScrollTarget = nil
            }
            .onChange(of: pendingChapterScroll) { _, index in
                // A chapter button was clicked: scroll to its opening turn.
                // We resolve against the full turn list (chapters index into
                // it) and only scroll when that turn is currently visible in
                // `filteredTurns` — a search may have hidden it.
                guard let index, index < chapters.count else {
                    pendingChapterScroll = nil
                    return
                }
                let chapter = chapters[index]
                guard chapter.turnIndices.lowerBound < turns.count else {
                    pendingChapterScroll = nil
                    return
                }
                let targetID = turns[chapter.turnIndices.lowerBound].id
                activeChapterIndex = index
                if filteredTurns.contains(where: { $0.id == targetID }) {
                    withAnimation { proxy.scrollTo(targetID, anchor: .top) }
                }
                pendingChapterScroll = nil
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
            HStack(spacing: 4) {
                // Bookmark badge for turns carrying a recording marker
                // (⌃⌥B / "Hey Nutola, mark this"). A leaf view observing the
                // shared marker store so badges flip without a manual version
                // bump. While viewing (not recording), clicking the badge
                // scrolls to the turn — so the same icon is the jump target.
                MarkerBadgeView(
                    store: markerStore,
                    meetingID: meeting.id,
                    turn: turn,
                    actionColor: actionColor,
                    tertiaryColor: Theme.tertiary(scheme),
                    isRecording: isRecordingThisMeeting,
                    onScrollToTurn: { markerScrollTarget = turn.id })
                pinButton(for: turn)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Subtle per-turn sentiment indicator (Speaker Sentiment Analysis).
            // Just the emoji colored by sentiment — no large UI changes. Sits
            // opposite the top-trailing pin/bookmark overlays so it never
            // collides with them, and only renders when a sentiment is found.
            if let sentiment = sentiment(for: turn) {
                Text(sentiment.emoji)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: sentiment.color) ?? Theme.tertiary(scheme))
                    .opacity(0.65)
                    .help("Sentiment: \(sentiment.rawValue)")
                    .accessibilityLabel("Sentiment \(sentiment.rawValue)")
                    .padding(4)
            }
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

    /// Dominant `Sentiment` for a turn, or `nil` if no matching segment was
    /// classified (e.g. empty transcript). A turn may span several merged
    /// segments; we pick the most urgent sentiment across them using the
    /// analyzer's precedence (critical > negative > positive > neutral),
    /// so a turn that mentions a blocker anywhere reads as critical.
    private func sentiment(for turn: TranscriptTurn) -> Sentiment? {
        guard !sentiments.isEmpty else { return nil }
        // A turn begins at the first segment that shares its speaker and
        // start time, and covers the next `segmentCount` same-speaker
        // segments from there.
        guard let start = segments.firstIndex(where: {
            $0.speakerID == turn.speakerID && $0.start == turn.start
        }) else { return nil }
        let slice = segments[start..<min(start + max(1, turn.segmentCount), segments.count)]
        let indices = Set(slice.startIndex..<slice.endIndex)
        let turnSentiments = sentiments.filter { indices.contains($0.segmentIndex) }
        // Precedence order — keep in sync with SentimentAnalyzer.
        for sentiment in [Sentiment.critical, .negative, .positive] {
            if turnSentiments.contains(where: { $0.sentiment == sentiment }) {
                return sentiment
            }
        }
        return turnSentiments.first?.sentiment ?? .neutral
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

    /// ⌃⌥B handler. While recording this meeting, drops a bookmark at the
 /// current recording timestamp via the live `RecordingSession`. While
 /// viewing (not recording), jumps to the next marker's turn — so the same
 /// hotkey doubles as a "next bookmark" navigation key on a finished
 /// transcript.
 private func addBookmarkOrJumpToNext() {
     if isRecordingThisMeeting, let session = app.session {
         session.addMarker(label: "Bookmark")
         return
     }
    // Viewing: jump to the turn carrying the first marker. Markers are
    // sorted by timestamp, so this lands on the earliest bookmark. This is
    // intentionally simple (no scroll-cursor tracking) since the reader has
    // no scroll-position observer.
    let meetingMarkers = markerStore.markers(for: meeting.id)
    guard let marker = meetingMarkers.first,
          let turn = turns.min(by: {
              abs($0.start - marker.timestamp) < abs($1.start - marker.timestamp)
          }) else { return }
    markerScrollTarget = turn.id
 }

    /// True when this meeting is the one currently being recorded — the
    /// ⌃⌥B bookmark hotkey drops a live marker in that state.
    private var isRecordingThisMeeting: Bool {
        app.session?.meetingID == meeting.id
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


/// The bookmark badge shown on transcript turns that carry a recording
/// marker (dropped via ⌃⌥B / "Hey Nutola, mark this"). Observes the shared
/// `TranscriptMarkerStore` directly so the icon appears the moment a marker
/// is added — no parent-view rebuild required. Kept as a tiny leaf view so
/// the rest of `TranscriptReaderView` doesn't observe the marker store.
///
/// While recording, the badge is display-only (markers come from the
/// `RecordingSession`). While viewing, clicking the badge scrolls to the
/// turn it badges — so the bookmark icon is also the jump target.
private struct MarkerBadgeView: View {
    @ObservedObject var store: TranscriptMarkerStore
    let meetingID: UUID
    let turn: TranscriptTurn
    let actionColor: Color
    let tertiaryColor: Color
    let isRecording: Bool
    let onScrollToTurn: () -> Void

    var body: some View {
        let marked = store.isMarked(meetingID: meetingID, timestamp: turn.start)
        // Only render when the turn actually carries a marker — keeps the
        // card clear of an empty icon when there's nothing to show.
        if marked {
            Button {
                // While viewing, the badge is the jump-to-turn target.
                if !isRecording { onScrollToTurn() }
            } label: {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(actionColor)
            }
            .buttonStyle(.plain)
            .help(isRecording ? "Bookmarked during recording" : "Jump to this bookmark")
            .accessibilityLabel(isRecording ? "Bookmarked turn" : "Jump to bookmark")
        }
    }
}