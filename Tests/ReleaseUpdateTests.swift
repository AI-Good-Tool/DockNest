import XCTest
@testable import DockFolderCore

final class ReleaseUpdateTests: XCTestCase {
    func testNumericVersionComparison() throws {
        let release = ReleaseUpdate(tagName: "v2.10.0", htmlURL: URL(string: "https://github.com/AI-Good-Tool/DockNest/releases/tag/v2.10.0")!, draft: false, prerelease: false)
        XCTAssertTrue(try release.isNewer(than: "2.7.0"))
        XCTAssertFalse(try release.isNewer(than: "2.10.0"))
        XCTAssertFalse(try release.isNewer(than: "3.0.0"))
    }

    func testRejectsInvalidRelease() {
        XCTAssertNil(ReleaseUpdate.components("v2.7.0-beta"))
        XCTAssertNil(ReleaseUpdate.components("2..0"))
        let invalid = ReleaseUpdate(tagName: "v9.0.0", htmlURL: URL(string: "https://example.com/download")!, draft: false, prerelease: false)
        XCTAssertThrowsError(try invalid.isNewer(than: "2.7.0"))
        let prerelease = ReleaseUpdate(tagName: "v9.0.0", htmlURL: URL(string: "https://github.com/AI-Good-Tool/DockNest/releases/tag/v9.0.0")!, draft: false, prerelease: true)
        XCTAssertThrowsError(try prerelease.isNewer(than: "2.7.0"))
    }
}
