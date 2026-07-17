import XCTest
@testable import Nutola

final class NemotronModelStoreTests: XCTestCase {
    func testManifestContainsNemoArchive() {
        let nemo = NemotronModelStore.manifest.first { $0.isPrimary }
        XCTAssertNotNil(nemo)
        XCTAssertTrue(nemo?.path.hasSuffix(".nemo") ?? false)
    }

    func testManifestHasExpectedFileCount() {
        XCTAssertEqual(NemotronModelStore.manifest.count, 6)
    }

    func testTotalSizeIsSumOfManifest() {
        let sum = NemotronModelStore.manifest.reduce(Int64(0)) { $0 + $1.size }
        XCTAssertEqual(NemotronModelStore.totalSize, sum)
    }

    func testTotalSizeIsMultiGB() {
        XCTAssertGreaterThan(NemotronModelStore.totalSize, 2_000_000_000)
    }

    func testFormatBytes() {
        XCTAssertFalse(NemotronModelStore.formatBytes(0).isEmpty)
        XCTAssertTrue(NemotronModelStore.formatBytes(1_500_000_000).contains("GB"))
        XCTAssertFalse(NemotronModelStore.formatBytes(500).isEmpty)
    }

    func testIsInstalledFalseWhenDirectoryAbsent() {
        _ = NemotronModelStore.isInstalled
    }

    func testInstalledBytesNonNegative() {
        XCTAssertGreaterThanOrEqual(NemotronModelStore.installedBytes, 0)
    }

    func testDirectoryPathUnderApplicationSupport() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        XCTAssertTrue(NemotronModelStore.directory.path.hasPrefix(appSupport.path))
        XCTAssertTrue(NemotronModelStore.directory.lastPathComponent == "Nemotron")
    }

    func testDeleteOnAbsentDirectoryReturnsZero() throws {
        let freed = try NemotronModelStore.delete()
        XCTAssertGreaterThanOrEqual(freed, 0)
    }
}
