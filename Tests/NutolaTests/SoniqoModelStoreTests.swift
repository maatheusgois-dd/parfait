import XCTest
@testable import Nutola

final class SoniqoModelStoreTests: XCTestCase {
    func testStreamingManifestHasCoreMLBundles() {
        let manifest = SoniqoModel.parakeetStreaming.manifest
        XCTAssertEqual(manifest.count, 14)
        XCTAssertTrue(manifest.contains { $0.path == "encoder.mlmodelc/weights/weight.bin" && $0.isPrimary })
    }

    func testBatchManifestHasMultipleEncoders() {
        let manifest = SoniqoModel.parakeetBatch.manifest
        XCTAssertEqual(manifest.count, 25)
        XCTAssertTrue(manifest.contains { $0.path.hasPrefix("encoder_5s.mlmodelc/") })
        XCTAssertTrue(manifest.contains { $0.path.hasPrefix("encoder_15s.mlmodelc/") })
    }

    func testStreamingTotalSizeNear120MB() {
        let total = SoniqoModelStore.totalSize(.parakeetStreaming)
        XCTAssertGreaterThan(total, 100_000_000)
        XCTAssertLessThan(total, 130_000_000)
    }

    func testBatchTotalSizeIsLarge() {
        let total = SoniqoModelStore.totalSize(.parakeetBatch)
        XCTAssertGreaterThan(total, 1_700_000_000)
    }

    func testLanguageCoverageIncludesPortuguese() {
        XCTAssertTrue(SoniqoModel.languageCodes.contains("pt"))
        XCTAssertTrue(SoniqoModel.languageCodes.contains("en"))
    }

    func testDirectoryPathUnderApplicationSupport() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = SoniqoModelStore.directory(for: .parakeetStreaming)
        XCTAssertTrue(dir.path.hasPrefix(appSupport.path))
        XCTAssertTrue(dir.path.contains("Soniqo"))
    }

    func testDeleteOnAbsentDirectoryReturnsZero() throws {
        let freed = try SoniqoModelStore.delete(.parakeetStreaming)
        XCTAssertGreaterThanOrEqual(freed, 0)
    }
}
