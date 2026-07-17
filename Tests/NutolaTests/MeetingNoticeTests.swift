import XCTest
@testable import Nutola

final class MeetingNoticeTests: XCTestCase {
    func testCanonicalTranscriptionFailuresCombine() {
        let notice = "\(MeetingNotice.micTranscriptionFailed) \(MeetingNotice.callTranscriptionFailed)"
        let presentation = MeetingNotice.presentation(for: notice)
        XCTAssertEqual(presentation?.title, "Couldn't transcribe this recording")
        XCTAssertTrue(presentation?.isEmptyTranscript == true)
    }

    func testLegacyAvfaudioErrorsBecomeFriendlyCopy() {
        let notice = """
        Mic transcription failed: The operation couldn't be completed. (com.apple.coreaudio.avfaudio error 1685348671.) \
        Call transcription failed: The operation couldn't be completed. (com.apple.coreaudio.avfaudio error 1685348671.)
        """
        let presentation = MeetingNotice.presentation(for: notice)
        XCTAssertEqual(presentation?.title, "Couldn't transcribe this recording")
        XCTAssertFalse(presentation?.message.contains("avfaudio") == true)
    }

    func testNoAudioTokenMapsToEmptyTranscript() {
        let presentation = MeetingNotice.presentation(for: MeetingNotice.noAudioTranscribed)
        XCTAssertEqual(presentation?.title, "No speech captured")
        XCTAssertTrue(presentation?.isEmptyTranscript == true)
    }

    func testEffectivePresentationHidesTotalFailureWhenTranscriptExists() {
        let notice = "\(MeetingNotice.micTranscriptionFailed) \(MeetingNotice.callTranscriptionFailed)"
        XCTAssertNil(MeetingNotice.effectivePresentation(for: notice, hasTranscript: true))
        XCTAssertNotNil(MeetingNotice.effectivePresentation(for: notice, hasTranscript: false))
    }

    func testEffectivePresentationKeepsPartialFailureWhenTranscriptExists() {
        let notice = MeetingNotice.micTranscriptionFailed
        let presentation = MeetingNotice.effectivePresentation(for: notice, hasTranscript: true)
        XCTAssertEqual(presentation?.title, "Your microphone wasn't transcribed")
        XCTAssertFalse(presentation?.isEmptyTranscript == true)
    }

    func testFinalizedNoticeClearsBothFailuresWhenTranscriptExists() {
        let notices = [MeetingNotice.micTranscriptionFailed, MeetingNotice.callTranscriptionFailed]
        XCTAssertNil(MeetingNotice.finalizedNotice(notices, hasTranscriptContent: true))
        XCTAssertEqual(
            MeetingNotice.finalizedNotice(notices, hasTranscriptContent: false),
            "\(MeetingNotice.micTranscriptionFailed) \(MeetingNotice.callTranscriptionFailed)")
    }

    func testFinalizedNoticeClearsLegacyBothFailuresWhenTranscriptExists() {
        let legacy = """
        Mic transcription failed: The operation couldn't be completed. (com.apple.coreaudio.avfaudio error 1685348671.) \
        Call transcription failed: The operation couldn't be completed. (com.apple.coreaudio.avfaudio error 1685348671.)
        """
        XCTAssertNil(MeetingNotice.finalizedNotice([legacy], hasTranscriptContent: true))
    }
}
