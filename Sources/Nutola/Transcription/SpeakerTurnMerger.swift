import Foundation

/// Combines Zoom AX speaker timelines with on-device diarization. Platform names
/// take precedence where they overlap; diarization fills gaps and unmapped clusters
/// keep anonymous "Speaker N" labels.
enum SpeakerTurnMerger {
    private static let minMappingOverlap: TimeInterval = 0.8
    private static let minGapDuration: TimeInterval = 0.25

    struct Result: Sendable {
        var turns: [DiarizedTurn]
        /// True when at least one turn carries a real Zoom/caption name.
        var hasNamedSpeakers: Bool
    }

    static func merge(
        platformEvents: [PlatformSpeakerEvent],
        diarized: [DiarizedTurn],
        roster: [String] = [],
        attendees: [String] = []
    ) -> Result {
        let platform = PlatformSpeakerTurnBuilder.turns(
            from: PlatformSpeakerTurnBuilder.normalized(platformEvents))
        guard !platform.isEmpty else {
            return Result(turns: normalize(diarized), hasNamedSpeakers: false)
        }
        guard !diarized.isEmpty else {
            return Result(turns: normalize(platform), hasNamedSpeakers: true)
        }

        let platformNorm = normalize(platform)
        var mapping = clusterToNameMapping(
            platformEvents: platformEvents, platform: platformNorm, diarized: diarized)
        mapping = applyRosterHints(
            mapping: mapping, diarized: diarized, platform: platformNorm,
            roster: roster, attendees: attendees)

        var result = platformNorm
        for dTurn in diarized {
            let speaker = mapping[dTurn.speaker] ?? dTurn.speaker
            let named = DiarizedTurn(speaker: speaker, start: dTurn.start, end: dTurn.end)
            result.append(contentsOf: subtractCoverage(named, coveredBy: platformNorm))
        }

        let merged = normalize(result)
        let named = Set(platformNorm.map(\.speaker))
        NutolaConsoleLog.speakers(
            "hybrid merge platform=\(platformNorm.count) diarized=\(diarized.count)"
                + " mapped=\(mapping.count) out=\(merged.count)"
                + " names=[\(named.sorted().joined(separator: ", "))]")
        return Result(turns: merged, hasNamedSpeakers: !named.isEmpty)
    }

    // MARK: - Cluster mapping

    private static func clusterToNameMapping(
        platformEvents: [PlatformSpeakerEvent],
        platform: [DiarizedTurn],
        diarized: [DiarizedTurn]
    ) -> [String: String] {
        let confidence = confidenceByInterval(platformEvents: platformEvents)
        var scores: [String: [String: Double]] = [:]

        for dTurn in diarized {
            for pTurn in platform {
                let overlap = overlapDuration(dTurn, pTurn)
                guard overlap >= minMappingOverlap else { continue }
                let weight = confidence[pTurn.speaker, default: 1.0]
                scores[dTurn.speaker, default: [:]][pTurn.speaker, default: 0] += overlap * weight
            }
        }

        var mapping: [String: String] = [:]
        for (cluster, nameScores) in scores {
            guard let best = nameScores.max(by: { $0.value < $1.value }) else { continue }
            mapping[cluster] = best.key
        }
        return mapping
    }

    private static func confidenceByInterval(
        platformEvents: [PlatformSpeakerEvent]
    ) -> [String: Double] {
        var out: [String: Double] = [:]
        for event in platformEvents {
            let weight: Double
            switch event.source {
            case .activeSpeaker: weight = 1.0
            case .caption: weight = 0.75
            case .selectedTile: weight = 0.55
            }
            out[event.name] = max(out[event.name, default: 0], weight)
        }
        return out
    }

    /// When exactly one roster/attendee name wasn't seen on the platform timeline,
    /// map a single leftover diarization cluster to that name.
    private static func applyRosterHints(
        mapping: [String: String],
        diarized: [DiarizedTurn],
        platform: [DiarizedTurn],
        roster: [String],
        attendees: [String]
    ) -> [String: String] {
        let known = Set(platform.map(\.speaker))
        let candidates = dedupedNames(roster + attendees)
            .filter { !ZoomActiveSpeakerReader.isLocalParticipant($0) }
            .filter { !known.contains($0) }
        guard candidates.count == 1, let name = candidates.first else { return mapping }

        let unmapped = Set(diarized.map(\.speaker)).subtracting(mapping.keys)
        guard unmapped.count == 1, let cluster = unmapped.first else { return mapping }

        var out = mapping
        out[cluster] = name
        NutolaConsoleLog.speakers("roster hint mapped \(cluster) → \(name)")
        return out
    }

    // MARK: - Interval algebra

    private static func subtractCoverage(
        _ turn: DiarizedTurn, coveredBy covering: [DiarizedTurn]
    ) -> [DiarizedTurn] {
        var uncovered: [(TimeInterval, TimeInterval)] = [(turn.start, turn.end)]
        for cover in covering {
            var next: [(TimeInterval, TimeInterval)] = []
            for (start, end) in uncovered {
                let overlapStart = max(start, cover.start)
                let overlapEnd = min(end, cover.end)
                if overlapStart >= overlapEnd {
                    next.append((start, end))
                } else {
                    if start < overlapStart { next.append((start, overlapStart)) }
                    if overlapEnd < end { next.append((overlapEnd, end)) }
                }
            }
            uncovered = next
        }
        return uncovered.compactMap { start, end in
            guard end - start >= minGapDuration else { return nil }
            return DiarizedTurn(speaker: turn.speaker, start: start, end: end)
        }
    }

    private static func overlapDuration(_ a: DiarizedTurn, _ b: DiarizedTurn) -> TimeInterval {
        max(0, min(a.end, b.end) - max(a.start, b.start))
    }

    private static func normalize(_ turns: [DiarizedTurn]) -> [DiarizedTurn] {
        guard !turns.isEmpty else { return [] }
        var out: [DiarizedTurn] = []
        for turn in turns.sorted(by: { $0.start < $1.start }) {
            guard turn.end > turn.start else { continue }
            if var last = out.last, last.speaker == turn.speaker, turn.start <= last.end + 0.5 {
                last.end = max(last.end, turn.end)
                out[out.count - 1] = last
            } else {
                out.append(turn)
            }
        }
        return out
    }

    private static func dedupedNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in names {
            let key = name.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(name)
        }
        return out
    }
}
