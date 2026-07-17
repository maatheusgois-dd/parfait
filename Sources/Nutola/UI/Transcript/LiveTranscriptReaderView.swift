import SwiftUI

struct LiveTranscriptReaderView: View {
    @ObservedObject var session: RecordingSession
    var priorSegments: [TranscriptSegment] = []
    var speakers: [Speaker] = []

    @EnvironmentObject private var app: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.nutolaActionColor) private var actionColor

    private var priorTurns: [TranscriptTurn] {
        TranscriptTurnBuilder.turns(from: priorSegments)
    }

    private var liveTurns: [TranscriptTurn] {
        TranscriptTurnBuilder.turns(from: session.liveSegments)
    }

    private var allTurns: [TranscriptTurn] {
        priorTurns + liveTurns
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            liveBanner

            if session.liveSegments.isEmpty, session.volatileText.isEmpty, priorSegments.isEmpty {
                EmptyStateView(
                    title: "Listening…",
                    message: "The live transcript appears here as people speak.")
                    .accessibilityLabel("Listening. The live transcript appears here as people speak.")
            } else {
                transcriptScroll
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    Task { await app.stopRecording() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.nutola(12, .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(actionColor)
                .accessibilityLabel("Stop recording")
                .accessibilityHint("Stops the recording and finalizes the transcript")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.thinMaterial)
        }
    }

    private var liveBanner: some View {
        HStack(spacing: 8) {
            RecordDot()
            Text(priorSegments.isEmpty
                 ? "Live — transcribing as the meeting happens. The final, more accurate transcript is created when you stop."
                 : "Live — new audio appends to the existing transcript when you stop.")
                .font(.nutola(11))
                .foregroundStyle(Theme.secondary(scheme))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.honey(scheme).opacity(0.12))
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(priorTurns) { turn in
                        turnCard(turn)
                    }

                    if !priorSegments.isEmpty, !session.liveSegments.isEmpty {
                        Text(MeetingArchive.timestamp(priorSegments.map(\.end).max() ?? 0))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.tertiary(scheme))
                            .frame(maxWidth: .infinity)
                    }

                    ForEach(liveTurns) { turn in
                        turnCard(turn)
                    }

                    if !session.volatileText.isEmpty {
                        VolatileTailView(text: session.volatileText)
                    }

                    Color.clear.frame(height: 1).id("live-bottom")
                }
                .frame(maxWidth: 660, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.liveSegments.count) { proxy.scrollTo("live-bottom", anchor: .bottom) }
            .onChange(of: session.volatileText) { proxy.scrollTo("live-bottom", anchor: .bottom) }
        }
    }

    private func turnCard(_ turn: TranscriptTurn) -> some View {
        let speakerID = turn.speakerID
        let displayName = name(for: speakerID)
        let color = TranscriptTurnBuilder.speakerColor(
            speakerID: speakerID,
            speakers: speakers,
            turns: allTurns,
            scheme: scheme)

        return TranscriptTurnCard(
            turn: turn,
            speakerName: displayName,
            speakerColor: color)
    }

    private func name(for speakerID: String) -> String {
        if speakerID == LiveTranscriber.othersSpeakerID,
           let active = session.activeRemoteSpeaker {
            return active
        }
        if let speaker = speakers.first(where: { $0.id == speakerID }) {
            return speaker.name
        }
        return LiveTranscriber.name(for: speakerID)
    }
}
