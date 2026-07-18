import SwiftUI

struct NotesTab: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.nutolaActionColor) private var actionColor
    let meeting: Meeting
    /// Owned by MeetingDetailView so tab switches can't drop an unsaved edit.
    @Binding var draft: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                templateMenu
                summaryBadge
                Spacer()
                if draft != nil {
                    Button("Cancel") { draft = nil }
                    Button("Save") {
                        if let draft { app.store.saveSummary(draft, for: meeting.id) }
                        draft = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(actionColor)
                } else {
                    // Direct Regenerate (one click) + template alternatives menu.
                    regenerateButton
                    Button {
                        draft = app.store.summary(for: meeting.id)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .disabled(summary.isEmpty || streaming != nil)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            if draft != nil {
                TextEditor(text: Binding(get: { draft ?? "" }, set: { draft = $0 }))
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .cardStyle()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            } else if displayed.isEmpty {
                if streaming != nil || app.processingStage[meeting.id] != nil {
                    EmptyStateView(
                        title: "Working on it…",
                        message: app.processingStage[meeting.id] ?? "Writing your notes…")
                } else {
                    EmptyStateView(
                        title: "No notes yet",
                        message: MeetingNotice.presentation(for: meeting.notice)?.message
                            ?? "Press Regenerate once the transcript exists, or check Settings → Intelligence.",
                        actionTitle: continueActionTitle,
                        action: continueAction)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ActionItemsPanel(meeting: meeting, summary: displayed)
                        MarkdownText(markdown: displayed)
                            .frame(maxWidth: 660, alignment: .leading)
                            .padding(14)
                            .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var summary: String { app.store.summary(for: meeting.id) }
    /// Notes streaming in right now (nil once a pass is saved). Shown in place of
    /// the saved summary so the reader watches the draft fill in.
    private var streaming: String? { app.streamingSummaries[meeting.id] }
    private var displayed: String { streaming ?? summary }

    private var continueActionTitle: String? {
        meeting.canContinueRecording(isRecording: app.isRecording) ? "Resume" : nil
    }

    private var continueAction: (() -> Void)? {
        guard continueActionTitle != nil else { return nil }
        return { Task { await app.continueRecording(meetingID: meeting.id) } }
    }

    /// "Writing…" while the draft streams; "Draft · improving" while the accurate
    /// transcript is being turned into the better version.
    @ViewBuilder
    private var summaryBadge: some View {
        if let progress = app.summaryProgress[meeting.id] {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text(progress == .improving ? "Draft · improving" : "Writing…")
                    .font(.nutola(11))
                    .foregroundStyle(.secondary)
            }
            .help(progress == .improving
                  ? "These notes were drafted from the live transcript. A more accurate version is on the way."
                  : "Writing notes from the transcript…")
        }
    }

    /// Selected template, shown as a capsule "pill" so the active choice is
    /// visible beyond the menu's text color (improvement #9).
    private var templateMenu: some View {
        Menu {
            ForEach(app.templates.list()) { template in
                Button(template.name) {
                    Task {
                        await app.regenerateSummary(
                            meetingID: meeting.id, templateName: template.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                Text(meeting.templateName ?? AppSettings.defaultTemplate)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tertiary(scheme))
            }
            .font(.nutola(12))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Theme.chip(scheme),
                in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Rewrite the notes with a different template")
    }

    /// Direct "Regenerate" trigger — one click regenerates with the current
    /// template (improvement #10). Template alternatives live in the trailing
    /// `templateMenu` so they stay one hover away without adding a second click
    /// to the common path.
    private var regenerateButton: some View {
        Button {
            Task { await app.regenerateSummary(meetingID: meeting.id) }
        } label: {
            Label("Regenerate", systemImage: "arrow.clockwise")
                .font(.nutola(12, .semibold))
        }
        .help("Regenerate notes with the current template")
        .disabled(streaming != nil || app.processingStage[meeting.id] != nil)
    }
}

struct TranscriptTab: View {
    @EnvironmentObject private var app: AppState
    let meeting: Meeting
    /// Owned by MeetingDetailView so tab switches can't drop an unsaved edit.
    @Binding var draft: String?

    private var segments: [TranscriptSegment] { app.store.transcript(for: meeting.id) }

    private var continueActionTitle: String? {
        meeting.canContinueRecording(isRecording: app.isRecording) ? "Resume" : nil
    }

    private var continueAction: (() -> Void)? {
        guard continueActionTitle != nil else { return nil }
        return { Task { await app.continueRecording(meetingID: meeting.id) } }
    }

    var body: some View {
        if let session = app.session, session.meetingID == meeting.id {
            LiveTranscriptReaderView(
                session: session,
                priorSegments: segments,
                speakers: meeting.speakers)
        } else {
            TranscriptReaderView(
                meeting: meeting,
                segments: segments,
                draft: $draft,
                continueActionTitle: continueActionTitle,
                continueAction: continueAction)
        }
    }
}

/// Read-only live transcript shown in the Transcript tab while a meeting is being
/// recorded (and mirrored by the floating recording card). Observes the session so
/// it updates in real time; the accurate, diarized transcript replaces it once
/// processing finishes.
typealias LiveTranscriptView = LiveTranscriptReaderView
