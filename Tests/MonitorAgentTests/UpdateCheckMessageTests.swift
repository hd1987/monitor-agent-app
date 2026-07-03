import XCTest
@testable import MonitorAgent

final class UpdateCheckMessageTests: XCTestCase {
    func testUpToDateDetailIncludesCurrentVersionCommitAndReleaseDate() {
        let detail = UpdateCheckMessage.upToDateDetail(
            versionWithCommit: "0.2.14 (7e7950d)",
            releaseDate: "Jun 23, 2026"
        )

        XCTAssertEqual(
            detail,
            """
            MonitorAgent 0.2.14 (7e7950d) is the latest version.
            Released Jun 23, 2026
            """
        )
    }

    func testNewVersionDetailIncludesCurrentBuildMetadataAndReleaseNotes() {
        let detail = UpdateCheckMessage.newVersionDetail(
            releaseBody: "Fixes and improvements.",
            currentVersionWithCommit: "0.2.14 (7e7950d)",
            currentReleaseDate: "Jun 23, 2026"
        )

        XCTAssertEqual(
            detail,
            """
            Current version: 0.2.14 (7e7950d)
            Released Jun 23, 2026

            Fixes and improvements.
            """
        )
    }

    func testNewVersionDetailOmitsMissingCurrentReleaseDate() {
        let detail = UpdateCheckMessage.newVersionDetail(
            releaseBody: "",
            currentVersionWithCommit: "0.2.14 (7e7950d)",
            currentReleaseDate: nil
        )

        XCTAssertEqual(
            detail,
            """
            Current version: 0.2.14 (7e7950d)

            A new version is ready to download.
            """
        )
    }
}
