import XCTest
@testable import Nutola

final class PinnedSegmentsTests: XCTestCase {
    var defaults: UserDefaults!
    var store: PinnedSegmentsStore!
    private var suite: String!

    override func setUp() {
        super.setUp()
        // A fresh, isolated UserDefaults suite per test so pins never leak
        // across tests or into the host app's .standard defaults.
        suite = "nutola-pins-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = PinnedSegmentsStore(defaults: defaults)
    }

    override func tearDown() {
        // Wipe the entire suite so nothing leaks between tests; the suite
        // is unique per test so we can safely remove the whole domain.
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = nil
        store = nil
        suite = nil
        super.tearDown()
    }

    private func makeTurn(
        id: String = "me-0",
        speakerID: String = "me",
        start: TimeInterval = 0,
        text: String = "Hello there."
    ) -> TranscriptTurn {
        TranscriptTurn(
            id: id, speakerID: speakerID, start: start,
            end: start + 2, text: text, segmentCount: 1)
    }

    func testPinTurn() {
        let meetingID = UUID()
        let turn = makeTurn(text: "Pick this up on Thursday.")
        store.pin(meetingID: meetingID, turn: turn, speakerName: "Me")

        let pins = store.pins(for: meetingID)
        XCTAssertEqual(pins.count, 1)
        XCTAssertEqual(pins.first?.turnID, turn.id)
        XCTAssertEqual(pins.first?.text, turn.text)
    }

    func testUnpinTurn() {
        let meetingID = UUID()
        let turn = makeTurn(text: "Action item: ship the build.")
        store.pin(meetingID: meetingID, turn: turn, speakerName: "Me")
        XCTAssertTrue(store.isPinned(meetingID: meetingID, turnID: turn.id))

        store.unpin(meetingID: meetingID, turnID: turn.id)
        XCTAssertFalse(store.isPinned(meetingID: meetingID, turnID: turn.id))
        XCTAssertTrue(store.pins(for: meetingID).isEmpty)
    }

    func testIsPinned() {
        let meetingID = UUID()
        let turn = makeTurn(text: "Worth coming back to.")
        XCTAssertFalse(store.isPinned(meetingID: meetingID, turnID: turn.id))

        store.pin(meetingID: meetingID, turn: turn, speakerName: "Me")
        XCTAssertTrue(store.isPinned(meetingID: meetingID, turnID: turn.id))
    }

    func testMultiplePins() {
        let meetingID = UUID()
        let a = makeTurn(id: "me-0", start: 0, text: "First point.")
        let b = makeTurn(id: "s1-5", speakerID: "s1", start: 5, text: "Second point.")
        let c = makeTurn(id: "me-12", start: 12, text: "Third point.")

        store.pin(meetingID: meetingID, turn: a, speakerName: "Me")
        store.pin(meetingID: meetingID, turn: b, speakerName: "Speaker 1")
        store.pin(meetingID: meetingID, turn: c, speakerName: "Me")

        let pins = store.pins(for: meetingID)
        XCTAssertEqual(pins.count, 3)
        XCTAssertTrue(store.isPinned(meetingID: meetingID, turnID: a.id))
        XCTAssertTrue(store.isPinned(meetingID: meetingID, turnID: b.id))
        XCTAssertTrue(store.isPinned(meetingID: meetingID, turnID: c.id))
    }

    func testPinsForDifferentMeetings() {
        let m1 = UUID()
        let m2 = UUID()
        let turn = makeTurn(text: "Same turn id, different meeting.")

        store.pin(meetingID: m1, turn: turn, speakerName: "Me")
        XCTAssertTrue(store.isPinned(meetingID: m1, turnID: turn.id))
        // The other meeting must not see this pin.
        XCTAssertFalse(store.isPinned(meetingID: m2, turnID: turn.id))
        XCTAssertTrue(store.pins(for: m2).isEmpty)

        // Pinning a different turn under m2 leaves m1 alone.
        let other = makeTurn(id: "s1-3", speakerID: "s1", start: 3, text: "Other meeting.")
        store.pin(meetingID: m2, turn: other, speakerName: "Speaker 1")
        XCTAssertEqual(store.pins(for: m1).count, 1)
        XCTAssertEqual(store.pins(for: m2).count, 1)
        XCTAssertEqual(store.pins(for: m2).first?.turnID, other.id)
    }

    func testPinTextAndSpeakerStored() {
        let meetingID = UUID()
        let turn = makeTurn(
            id: "s2-42", speakerID: "s2", start: 42.5,
            text: "Let's circle back to the pricing model.")
        store.pin(meetingID: meetingID, turn: turn, speakerName: "Jordan")

        let pin = store.pins(for: meetingID).first
        XCTAssertNotNil(pin)
        XCTAssertEqual(pin?.meetingID, meetingID)
        XCTAssertEqual(pin?.turnID, "s2-42")
        XCTAssertEqual(pin?.speakerID, "s2")
        XCTAssertEqual(pin?.text, "Let's circle back to the pricing model.")
        XCTAssertEqual(pin?.timestamp ?? -1, 42.5, accuracy: 0.001)
        // speakerName is a UI convenience for rendering, not persisted on the pin.
        XCTAssertNotNil(pin?.pinnedAt)
    }

    func testPinIsIdempotent() {
        let meetingID = UUID()
        let turn = makeTurn(text: "Pin me twice, expect one pin.")
        store.pin(meetingID: meetingID, turn: turn, speakerName: "Me")
        store.pin(meetingID: meetingID, turn: turn, speakerName: "Me")
        XCTAssertEqual(store.pins(for: meetingID).count, 1)
    }

    func testToggleFlipsPinState() {
        let meetingID = UUID()
        let turn = makeTurn(text: "Toggle me.")

        let pinned = store.toggle(meetingID: meetingID, turn: turn, speakerName: "Me")
        XCTAssertTrue(pinned)
        XCTAssertTrue(store.isPinned(meetingID: meetingID, turnID: turn.id))

        let unpinned = store.toggle(meetingID: meetingID, turn: turn, speakerName: "Me")
        XCTAssertFalse(unpinned)
        XCTAssertFalse(store.isPinned(meetingID: meetingID, turnID: turn.id))
    }

    func testUnpinNotPinnedIsNoOp() {
        let meetingID = UUID()
        let turn = makeTurn(text: "Never pinned.")
        store.unpin(meetingID: meetingID, turnID: turn.id) // should not throw / mutate
        XCTAssertTrue(store.pins(for: meetingID).isEmpty)
    }

    func testPinsReturnInInsertionOrder() {
        let meetingID = UUID()
        let a = makeTurn(id: "me-0", start: 0, text: "First pinned.")
        let b = makeTurn(id: "me-5", start: 5, text: "Second pinned.")
        let c = makeTurn(id: "me-9", start: 9, text: "Third pinned.")

        store.pin(meetingID: meetingID, turn: a, speakerName: "Me")
        store.pin(meetingID: meetingID, turn: b, speakerName: "Me")
        store.pin(meetingID: meetingID, turn: c, speakerName: "Me")

        let pins = store.pins(for: meetingID)
        XCTAssertEqual(pins.count, 3)
        // Pins come back in the order they were added, oldest first.
        XCTAssertEqual(pins.map(\.turnID), ["me-0", "me-5", "me-9"], "insertion order preserved")
    }

    func testPersistAcrossStoreInstances() {
        // A new store reading the same defaults sees previously-pinned turns —
        // the persistence layer is UserDefaults, not in-memory state.
        let meetingID = UUID()
        let turn = makeTurn(text: "Survives a restart.")
        store.pin(meetingID: meetingID, turn: turn, speakerName: "Me")

        let revived = PinnedSegmentsStore(defaults: defaults)
        XCTAssertEqual(revived.pins(for: meetingID).count, 1)
        XCTAssertEqual(revived.pins(for: meetingID).first?.turnID, turn.id)
    }
}
