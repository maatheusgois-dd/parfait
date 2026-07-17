import XCTest
@testable import Nutola

final class TranscriptionModelTests: XCTestCase {
    func testRawValuesRoundTrip() {
        for model in TranscriptionModel.allCases {
            XCTAssertEqual(TranscriptionModel(rawValue: model.rawValue), model)
        }
    }

    func testDefaultIsApple() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.transcriptionModel)
        XCTAssertEqual(AppSettings.transcriptionModel, .apple)
    }

    func testPersistsChoice() {
        UserDefaults.standard.set(TranscriptionModel.parakeetStreaming.rawValue, forKey: SettingsKey.transcriptionModel)
        // parakeetStreaming's inference engine is wired, so the getter returns it.
        XCTAssertEqual(AppSettings.transcriptionModel, .parakeetStreaming)
        UserDefaults.standard.removeObject(forKey: SettingsKey.transcriptionModel)
        XCTAssertEqual(AppSettings.transcriptionModel, .apple)
    }

    func testDisplayNameNonEmpty() {
        for model in TranscriptionModel.allCases {
            XCTAssertFalse(model.displayName.isEmpty)
            XCTAssertFalse(model.detail.isEmpty)
        }
    }

    func testDownloadableModels() {
        XCTAssertFalse(TranscriptionModel.apple.isDownloadable)
        XCTAssertTrue(TranscriptionModel.nemotron.isDownloadable)
        XCTAssertTrue(TranscriptionModel.parakeetStreaming.isDownloadable)
        XCTAssertTrue(TranscriptionModel.parakeetBatch.isDownloadable)
    }

    func testIsAvailable() {
        // All engines are selectable: Parakeet and Nemotron download weights
        // managed by their stores, like Apple's on-device assets. The user's
        // choice round-trips through AppSettings.transcriptionModel.
        for model in TranscriptionModel.allCases {
            XCTAssertTrue(model.isAvailable, "\(model.rawValue) should be selectable")
        }
    }

    func testEveryModelPersistsAndRoundTrips() {
        for model in TranscriptionModel.allCases {
            UserDefaults.standard.set(model.rawValue, forKey: SettingsKey.transcriptionModel)
            XCTAssertEqual(AppSettings.transcriptionModel, model,
                           "\(model.rawValue) should round-trip via AppSettings")
        }
        UserDefaults.standard.removeObject(forKey: SettingsKey.transcriptionModel)
        XCTAssertEqual(AppSettings.transcriptionModel, .apple)
    }

    func testSoniqoMapping() {
        XCTAssertEqual(TranscriptionModel.parakeetStreaming.soniqoModel, .parakeetStreaming)
        XCTAssertEqual(TranscriptionModel.parakeetBatch.soniqoModel, .parakeetBatch)
        XCTAssertNil(TranscriptionModel.apple.soniqoModel)
        XCTAssertNil(TranscriptionModel.nemotron.soniqoModel)
    }

    func testLiveVsBatchMode() {
        XCTAssertTrue(TranscriptionModel.parakeetStreaming.supportsLiveTranscription)
        XCTAssertFalse(TranscriptionModel.parakeetBatch.supportsLiveTranscription)
    }
}
