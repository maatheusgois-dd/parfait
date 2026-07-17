import XCTest
@testable import Nutola

final class SpeakerTurnMergerTests: XCTestCase {
    private func turn(_ speaker: String, _ start: TimeInterval, _ end: TimeInterval) -> DiarizedTurn {
        DiarizedTurn(speaker: speaker, start: start, end: end)
    }

    private func event(
        _ name: String, _ start: TimeInterval, _ end: TimeInterval,
        source: PlatformSpeakerSource = .activeSpeaker
    ) -> PlatformSpeakerEvent {
        PlatformSpeakerEvent(name: name, start: start, end: end, source: source)
    }

    func testPlatformOnlyWhenNoDiarization() {
        let events = [event("Alice", 0, 5), event("Bob", 6, 10)]
        let result = SpeakerTurnMerger.merge(platformEvents: events, diarized: [])
        XCTAssertEqual(result.turns.map(\.speaker), ["Alice", "Bob"])
        XCTAssertTrue(result.hasNamedSpeakers)
    }

    func testDiarizationOnlyWhenNoPlatform() {
        let diarized = [turn("S1", 0, 4), turn("S2", 5, 9)]
        let result = SpeakerTurnMerger.merge(platformEvents: [], diarized: diarized)
        XCTAssertEqual(result.turns.count, 2)
        XCTAssertFalse(result.hasNamedSpeakers)
    }

    func testHybridFillsGapsWithMappedClusters() {
        // Zoom caught Alice 0-3s; diarization has S1 0-10 and S2 10-20.
        let events = [event("Alice", 0, 3)]
        let diarized = [turn("S1", 0, 10), turn("S2", 10, 20)]
        let result = SpeakerTurnMerger.merge(platformEvents: events, diarized: diarized)

        XCTAssertTrue(result.turns.contains { $0.speaker == "Alice" && $0.start == 0 && $0.end == 10 })
        XCTAssertTrue(result.turns.contains { $0.speaker == "S2" && $0.start == 10 })
        XCTAssertTrue(result.hasNamedSpeakers)
    }

    func testPlatformWinsOnOverlap() {
        let events = [event("Alice", 2, 6)]
        let diarized = [turn("S1", 0, 8)]
        let result = SpeakerTurnMerger.merge(platformEvents: events, diarized: diarized)

        // S1 maps to Alice via overlap; the whole cluster inherits the Zoom name.
        XCTAssertEqual(result.turns.count, 1)
        XCTAssertEqual(result.turns[0].speaker, "Alice")
        XCTAssertEqual(result.turns[0].start, 0)
        XCTAssertEqual(result.turns[0].end, 8)
    }

    func testCaptionEventsMapClusters() {
        let events = [
            event("Bob", 5, 6, source: .caption),
            event("Bob", 12, 13, source: .caption),
        ]
        let diarized = [turn("S1", 0, 20)]
        let result = SpeakerTurnMerger.merge(platformEvents: events, diarized: diarized)
        XCTAssertTrue(result.turns.allSatisfy { $0.speaker == "Bob" })
    }

    func testRosterHintMapsSingleLeftoverCluster() {
        let events = [event("Alice", 0, 5)]
        let diarized = [turn("S1", 0, 5), turn("S2", 6, 12)]
        let result = SpeakerTurnMerger.merge(
            platformEvents: events, diarized: diarized, roster: ["Alice", "Bob"], attendees: [])
        XCTAssertTrue(result.turns.contains { $0.speaker == "Bob" && $0.start >= 6 })
    }
}
