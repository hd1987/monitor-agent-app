import XCTest
@testable import MonitorAgent

final class UpdateCheckMessageTests: XCTestCase {
    func testUpdateDownloadStagerUsesUniqueDestinationAndMovesDownloadedFile() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let source = directory.appendingPathComponent("download.tmp")
        let contents = Data("archive".utf8)
        try contents.write(to: source)
        let identifier = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!

        let destination = try UpdateDownloadStager.stage(
            downloadedFile: source,
            in: directory,
            fileManager: fileManager,
            identifier: identifier
        )

        XCTAssertEqual(destination.lastPathComponent, "MonitorAgent-update-12345678-1234-1234-1234-123456789ABC.zip")
        XCTAssertFalse(fileManager.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), contents)
    }

    func testUpdateDownloadStagerThrowsWhenDownloadedFileIsMissing() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        XCTAssertThrowsError(
            try UpdateDownloadStager.stage(
                downloadedFile: directory.appendingPathComponent("missing.tmp"),
                in: directory,
                fileManager: fileManager
            )
        )
    }

    func testNewVersionDialogStateSeparatesMetadataAndReleaseNotes() {
        let state = UpdateCheckDialogState.newVersion(
            tagName: "v0.2.16",
            currentVersionWithCommit: "0.2.15 (36dd217)",
            currentReleaseDate: "Jul 3, 2026",
            releaseBody: "Fix update dialog layout."
        )

        XCTAssertEqual(state.title, "New version available")
        XCTAssertEqual(state.subtitle, "v0.2.16 is ready to install.")
        XCTAssertEqual(state.detail, "Current version: 0.2.15 (36dd217)\nReleased Jul 3, 2026")
        XCTAssertEqual(state.releaseNotesTitle, "Release Notes")
        XCTAssertEqual(state.releaseNotes, "Fix update dialog layout.")
        XCTAssertEqual(state.primaryButton?.title, "Update")
        XCTAssertEqual(state.primaryButton?.action, .startDownload)
        XCTAssertEqual(state.secondaryButton?.title, "Later")
        XCTAssertEqual(state.secondaryButton?.action, .close)
    }

    func testDownloadingDialogStateShowsDeterminateProgress() {
        let state = UpdateCheckDialogState.downloading(
            tagName: "v0.2.16",
            fraction: 0.5,
            downloadedMegabytes: 4.2,
            totalMegabytes: 8.4
        )

        XCTAssertEqual(state.title, "Downloading v0.2.16")
        XCTAssertEqual(state.progress, .determinate(0.5))
        XCTAssertEqual(state.detail, "4.2 / 8.4 MB")
        XCTAssertEqual(state.secondaryButton?.title, "Cancel")
    }

    func testUpdateCompleteDialogStateRequiresRestart() {
        let state = UpdateCheckDialogState.updateComplete()

        XCTAssertEqual(state.title, "Update complete")
        XCTAssertEqual(state.detail, "Restart to apply the update.")
        XCTAssertEqual(state.primaryButton?.title, "Restart")
        XCTAssertEqual(state.primaryButton?.action, .restartApp)
        XCTAssertEqual(state.secondaryButton?.title, "Later")
    }

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
