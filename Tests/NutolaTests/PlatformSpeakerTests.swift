import XCTest
@testable import Nutola

final class PlatformSpeakerTests: XCTestCase {
    func testParseSpeakingLabels() {
        XCTAssertEqual(
            ZoomActiveSpeakerReader.parseSpeakingLabel("Jimmy Veloso, unmuted"),
            "Jimmy Veloso")
        XCTAssertEqual(
            ZoomActiveSpeakerReader.parseZoomParticipantDescription(
                "Gui Lima, Computer audio unmuted, Video on"),
            "Gui Lima")
        XCTAssertEqual(
            ZoomActiveSpeakerReader.parseSpeakingLabel("Acquila Santos Rocha is speaking"),
            "Acquila Santos Rocha")
        XCTAssertEqual(
            ZoomActiveSpeakerReader.parseSpeakingLabel("Speaking: Gui Lima"),
            "Gui Lima")
        XCTAssertEqual(
            ZoomActiveSpeakerReader.parseZoomTileDescription(
                "Paulo Henrique Paulin, Computer audio unmuted, Video on, active speaker"),
            "Paulo Henrique Paulin")
        XCTAssertEqual(
            ZoomActiveSpeakerReader.parseZoomTileDescription(
                "Gui Lima, Computer audio unmuted, Video on"),
            nil)
        XCTAssertNil(ZoomActiveSpeakerReader.parseSpeakingLabel("Mute"))
        XCTAssertNil(ZoomActiveSpeakerReader.parseSpeakingLabel("Participants"))
        // Regression: unmuted gallery tiles are roster metadata, not speaking labels.
        XCTAssertNil(
            ZoomActiveSpeakerReader.parseSpeakingLabel(
                "Gui Lima, Computer audio unmuted, Video on"))
        XCTAssertNil(
            ZoomActiveSpeakerReader.parseSpeakingLabel(
                "Acquila Santos Rocha, Computer audio unmuted, Video on"))
    }

    func testIsLocalParticipantFilteredFromActive() {
        let full = NSFullUserName()
        guard !full.isEmpty else { return }
        XCTAssertTrue(ZoomActiveSpeakerReader.isLocalParticipant(full))
        let first = full.split(separator: " ").prefix(2).joined(separator: " ")
        if first != full {
            XCTAssertTrue(ZoomActiveSpeakerReader.isLocalParticipant(first))
        }
        XCTAssertFalse(ZoomActiveSpeakerReader.isLocalParticipant("Totally Different Person"))
    }

    func testActiveSpeakerIgnoresUnmutedGalleryTiles() {
        let tiles = [
            "Acquila Santos Rocha, Computer audio unmuted, Video on",
            "Gui Lima, Computer audio unmuted, Video on",
            "Victor Moura de Britto, Computer audio unmuted, Video on, active speaker",
            "Paulo Henrique Paulin, Computer audio unmuted, Video on",
        ]
        let roster = tiles.compactMap { ZoomActiveSpeakerReader.parseZoomParticipantDescription($0) }
        let active = tiles.compactMap { ZoomActiveSpeakerReader.parseZoomTileDescription($0) }
        XCTAssertEqual(roster.count, 4)
        XCTAssertEqual(active, ["Victor Moura de Britto"])
    }

    func testActiveSpeakerNamesFromZoomTileDescriptions() {
        // Regression: Zoom Workplace exposes active speaker on AXTabGroup descriptions.
        let samples = [
            "Matheus Gois, Computer audio unmuted, Video on",
            "Gui Lima, Computer audio unmuted, Video on",
            "Paulo Henrique Paulin, Computer audio unmuted, Video on, active speaker",
        ]
        let names = samples.compactMap { ZoomActiveSpeakerReader.parseZoomTileDescription($0) }
        XCTAssertEqual(names, ["Paulo Henrique Paulin"])
    }

    func testNormalizedMergesAdjacentSameName() {
        let events = [
            PlatformSpeakerEvent(name: "Alice", start: 0, end: 2),
            PlatformSpeakerEvent(name: "Alice", start: 2.2, end: 5),
            PlatformSpeakerEvent(name: "Bob", start: 6, end: 8),
        ]
        let out = PlatformSpeakerTurnBuilder.normalized(events)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].name, "Alice")
        XCTAssertEqual(out[0].start, 0)
        XCTAssertEqual(out[0].end, 5)
        XCTAssertEqual(out[1].name, "Bob")
    }

    func testNamedSpeakersUseDisplayNames() {
        let system = TranscriptionOutput(
            words: [
                TranscribedWord(text: "hello", start: 0.0, end: 0.5),
                TranscribedWord(text: "there", start: 0.6, end: 1.0),
                TranscribedWord(text: "hi", start: 3.0, end: 3.4),
            ],
            segments: []
        )
        let turns = [
            DiarizedTurn(speaker: "Jimmy Veloso", start: 0, end: 2),
            DiarizedTurn(speaker: "Gui Lima", start: 2.5, end: 4),
        ]
        let (_, speakers) = SpeakerLabeler.label(
            mic: nil,
            system: system,
            systemTurns: turns,
            myName: "Me",
            namedSpeakers: true)

        XCTAssertEqual(speakers.map(\.name), ["Jimmy Veloso", "Gui Lima"])
    }

    func testParseZoomCaptionLine() {
        XCTAssertEqual(
            ZoomActiveSpeakerReader.parseZoomCaptionLine("Gui Lima: hello everyone")?.name,
            "Gui Lima")
        XCTAssertEqual(
            ZoomActiveSpeakerReader.parseZoomCaptionLine("Paulo said: let's ship it")?.name,
            "Paulo")
        XCTAssertNil(ZoomActiveSpeakerReader.parseZoomCaptionLine("Mute"))
    }

    func testParseParticipantRow() {
        XCTAssertEqual(ZoomActiveSpeakerReader.parseParticipantRow("Victor Moura"), "Victor Moura")
        XCTAssertNil(ZoomActiveSpeakerReader.parseParticipantRow("Participants (5)"))
        XCTAssertNil(
            ZoomActiveSpeakerReader.parseParticipantRow(
                "Gui Lima, Computer audio unmuted, Video on"))
    }
}
