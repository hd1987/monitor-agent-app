import XCTest
@testable import MonitorAgent

final class AppInstallerTests: XCTestCase {
    private enum ReplacementError: Error {
        case failed
    }

    func testFailedExtractionPreservesInstalledApp() throws {
        let directory = try makeTemporaryDirectory()
        let destination = directory.appendingPathComponent("MonitorAgent.app", isDirectory: true)
        let existingMarker = destination.appendingPathComponent("existing.txt")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: existingMarker)

        let installed = AppInstaller.install(
            zipURL: directory.appendingPathComponent("update.zip"),
            destinationURL: destination,
            extractor: { _, _ in false }
        )

        XCTAssertFalse(installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingMarker.path))
    }

    func testValidatedAppReplacesInstalledApp() throws {
        let directory = try makeTemporaryDirectory()
        let destination = directory.appendingPathComponent("MonitorAgent.app", isDirectory: true)
        let existingMarker = destination.appendingPathComponent("existing.txt")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: existingMarker)

        let installed = AppInstaller.install(
            zipURL: directory.appendingPathComponent("update.zip"),
            destinationURL: destination,
            extractor: { _, stagingDirectory in
                self.createValidApp(in: stagingDirectory)
            }
        )

        XCTAssertTrue(installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: existingMarker.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("Contents/MacOS/MonitorAgent").path
            )
        )
    }

    func testReplacementFailureRestoresInstalledAppFromBackup() throws {
        let directory = try makeTemporaryDirectory()
        let destination = directory.appendingPathComponent("MonitorAgent.app", isDirectory: true)
        let existingMarker = destination.appendingPathComponent("existing.txt")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: existingMarker)

        let installed = AppInstaller.install(
            zipURL: directory.appendingPathComponent("update.zip"),
            destinationURL: destination,
            extractor: { _, stagingDirectory in
                self.createValidApp(in: stagingDirectory)
            },
            replacer: { fileManager, destinationURL, _, backupName in
                let backupURL = destinationURL.deletingLastPathComponent()
                    .appendingPathComponent(backupName)
                try fileManager.moveItem(at: destinationURL, to: backupURL)
                throw ReplacementError.failed
            }
        )

        XCTAssertFalse(installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingMarker.path))
    }

    func testInvalidBundlePreservesInstalledApp() throws {
        let directory = try makeTemporaryDirectory()
        let destination = directory.appendingPathComponent("MonitorAgent.app", isDirectory: true)
        let existingMarker = destination.appendingPathComponent("existing.txt")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: existingMarker)

        let installed = AppInstaller.install(
            zipURL: directory.appendingPathComponent("update.zip"),
            destinationURL: destination,
            extractor: { _, stagingDirectory in
                self.createValidApp(in: stagingDirectory, bundleIdentifier: "invalid.bundle")
            }
        )

        XCTAssertFalse(installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingMarker.path))
    }

    func testNonExecutableBundlePreservesInstalledApp() throws {
        let directory = try makeTemporaryDirectory()
        let destination = directory.appendingPathComponent("MonitorAgent.app", isDirectory: true)
        let existingMarker = destination.appendingPathComponent("existing.txt")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: existingMarker)

        let installed = AppInstaller.install(
            zipURL: directory.appendingPathComponent("update.zip"),
            destinationURL: destination,
            extractor: { _, stagingDirectory in
                self.createValidApp(in: stagingDirectory, makeExecutable: false)
            }
        )

        XCTAssertFalse(installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingMarker.path))
    }

    private func createValidApp(
        in stagingDirectory: URL,
        bundleIdentifier: String = "com.hd1987.monitor-agent",
        makeExecutable: Bool = true
    ) -> Bool {
        let app = stagingDirectory.appendingPathComponent("MonitorAgent.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let executableDirectory = contents.appendingPathComponent("MacOS", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
            let executable = executableDirectory.appendingPathComponent("MonitorAgent")
            try Data("binary".utf8).write(to: executable)
            if makeExecutable {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: executable.path
                )
            }
            let info: NSDictionary = [
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundleExecutable": "MonitorAgent",
                "CFBundlePackageType": "APPL",
            ]
            return info.write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        } catch {
            return false
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MonitorAgentInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
