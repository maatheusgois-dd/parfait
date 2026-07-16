import XCTest
@testable import Parfait

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
