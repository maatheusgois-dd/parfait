import Foundation

/// Embeds Nutola meeting data into ask prompts so answers don't depend on
/// MCP tool round-trips (non-interactive CLI runs can't reliably finish them).
enum AskContextBuilder {
    private static let uuidPattern = #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#

    struct Limits {
        let includeList: Bool
        let listLimit: Int
        let summaryMaxChars: Int
        let transcriptMaxChars: Int
        let maxTotalChars: Int?

        static let cloud = Limits(
            includeList: true, listLimit: 30, summaryMaxChars: 8_000,
            transcriptMaxChars: 80_000, maxTotalChars: nil)
        /// On-device model (~4k tokens). Summaries only — skip the title list that
        /// tempts the model to count meetings by timestamp instead of synthesizing.
        static let onDevice = Limits(
            includeList: false, listLimit: 0, summaryMaxChars: 1_200,
            transcriptMaxChars: 3_500, maxTotalChars: AppleSummarizer.askContextBudgetChars)
    }

    static func enrichForCLI(_ prompt: String, archive: MeetingArchive = MeetingArchive()) -> String {
        enrichForAsk(prompt, archive: archive, limits: .cloud)
    }

    static func enrichForAsk(
        _ prompt: String,
        archive: MeetingArchive = MeetingArchive(),
        limits: Limits = .cloud
    ) -> String {
        let server = MCPServer(archive: archive, templates: TemplateStore())
        var blocks: [String] = []

        for id in uuids(in: prompt) {
            guard archive.meeting(id: id) != nil else { continue }
            let idString = id.uuidString
            if let meetingText = try? server.call(tool: "get_meeting", arguments: ["id": idString]),
               let transcript = try? server.call(tool: "get_transcript", arguments: ["id": idString]) {
                blocks.append(
                    """
                    ## Meeting \(idString)
                    \(meetingText)

                    ### Transcript
                    \(truncate(transcript, maxChars: limits.transcriptMaxChars))
                    """
                )
            }
        }

        if blocks.isEmpty {
            let ready = archive.allMeetings().filter { $0.state == .ready }
            if !ready.isEmpty {
                let weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
                let thisWeek = ready.filter { $0.createdAt >= weekStart }
                let candidates = thisWeek.isEmpty ? ready : thisWeek
                let withSummaries = candidates.filter {
                    !archive.summary(for: $0.id)
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }

                if limits.includeList,
                   let list = try? server.call(tool: "list_meetings", arguments: ["limit": limits.listLimit]) {
                    blocks.append("## Recent meetings\n\(list)")
                }

                if !withSummaries.isEmpty {
                    blocks.append(
                        "## \(withSummaries.count) meeting\(withSummaries.count == 1 ? "" : "s") "
                            + "this week — synthesize from the summaries below, not timestamps"
                    )
                    for meeting in withSummaries {
                        let summary = truncate(
                            archive.summary(for: meeting.id), maxChars: limits.summaryMaxChars)
                        blocks.append("## \(meeting.title)\n\(summary)")
                    }
                }

                let withoutSummaries = candidates.count - withSummaries.count
                if withoutSummaries > 0 {
                    blocks.append(
                        "(\(withoutSummaries) other meeting\(withoutSummaries == 1 ? "" : "s") "
                            + "this week had no notes yet.)"
                    )
                }
            }
        }

        guard !blocks.isEmpty else { return prompt }

        return assemble(
            prompt: prompt,
            blocks: blocks,
            maxChars: limits.maxTotalChars
        )
    }

    private static func assemble(prompt: String, blocks: [String], maxChars: Int?) -> String {
        let header = """
        \(prompt)

        ---

        Meeting data from Nutola (already loaded below — answer immediately from this; do not say you will look up, fetch, or call tools):

        """
        guard let maxChars else {
            return header + blocks.joined(separator: "\n\n")
        }

        // Drop summary blocks from the end until the prompt fits; never truncate mid-summary.
        var kept = blocks
        while !kept.isEmpty {
            let body = kept.joined(separator: "\n\n")
            let full = header + body
            if full.count <= maxChars { return full }
            if kept.count == 1 {
                return String(full.prefix(maxChars)) + "\n\n[context truncated…]"
            }
            kept.removeLast()
        }
        return prompt
    }

    private static func uuids(in text: String) -> [UUID] {
        guard let regex = try? NSRegularExpression(pattern: uuidPattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var seen = Set<UUID>()
        var ordered: [UUID] = []
        for match in matches {
            guard let id = UUID(uuidString: ns.substring(with: match.range)),
                  seen.insert(id).inserted
            else { continue }
            ordered.append(id)
        }
        return ordered
    }

    private static func truncate(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        return String(text.prefix(maxChars)) + "\n\n[truncated…]"
    }
}
