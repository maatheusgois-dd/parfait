import SwiftUI

struct TranscriptTurnCard: View {
    @Environment(\.colorScheme) private var scheme

    let turn: TranscriptTurn
    let speakerName: String
    let speakerColor: Color
    var dimmed = false
    var onRename: (() -> Void)?

    private let railWidth: CGFloat = 3
    private let cornerRadius: CGFloat = 12

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: railWidth / 2)
                .fill(speakerColor)
                .frame(width: railWidth)
                .padding(.vertical, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let onRename {
                        Button(action: onRename) {
                            Text(speakerName)
                                .font(.nutola(12, .bold))
                                .foregroundStyle(speakerColor)
                        }
                        .buttonStyle(.plain)
                        .help("Rename this speaker everywhere")
                        .accessibilityLabel("Rename speaker \(speakerName)")
                        .accessibilityHint("Rename this speaker everywhere in this meeting")
                    } else {
                        Text(speakerName)
                            .font(.nutola(12, .bold))
                            .foregroundStyle(speakerColor)
                    }
                    Text(MeetingArchive.timestamp(turn.start))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.tertiary(scheme))
                    Spacer(minLength: 0)
                }

                Text(turn.text)
                    .font(.nutola(13))
                    .foregroundStyle(Theme.ink(scheme))
                    .textSelection(.enabled)
                    .lineSpacing(2)
            }
            .padding(.leading, 12)
        }
        .padding(14)
        .background(Theme.card(scheme), in: RoundedRectangle(cornerRadius: cornerRadius))
        .opacity(dimmed ? 0.45 : 1)
        // Collapse the card into one VoiceOver element so a turn reads as a unit:
        // "<speaker> at <timestamp>: <text>". The rename button stays reachable as
        // an accessibility action when onRename is set.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(speakerName) at \(MeetingArchive.timestamp(turn.start)): \(turn.text)")
        .accessibilityAddTraits(dimmed ? [.isStaticText, .updatesFrequently] : [.isStaticText])
        .ifLet(onRename) { view, rename in
            view.accessibilityAction(named: "Rename speaker \(speakerName)", rename)
        }
    }
}

struct VolatileTailView: View {
    @Environment(\.colorScheme) private var scheme

    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.honey(scheme).opacity(0.5))
                .frame(width: 3)
                .padding(.vertical, 2)
                .accessibilityHidden(true)

            Text(text)
                .font(.nutola(13))
                .foregroundStyle(Theme.secondary(scheme))
                .italic()
                .textSelection(.enabled)
                .lineSpacing(2)
                .padding(.leading, 12)
        }
        .padding(14)
        .background(
            Theme.card(scheme).opacity(0.65),
            in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live, not yet finalized: \(text)")
        .accessibilityAddTraits([.isStaticText, .updatesFrequently])
    }
}
