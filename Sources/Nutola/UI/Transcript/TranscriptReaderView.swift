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

    private var turns: [TranscriptTurn] {
        TranscriptTurnBuilder.turns(from: segments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar

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
    }

    private var toolbar: some View {
        HStack {
            if !segments.isEmpty {
                Text(statsLabel)
                    .font(.nutola(11))
                    .foregroundStyle(Theme.tertiary(scheme))
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(turns) { turn in
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
                }
            }
            .frame(maxWidth: 660, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    private func name(for speakerID: String) -> String {
        meeting.speakers.first { $0.id == speakerID }?.name ?? speakerID
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
