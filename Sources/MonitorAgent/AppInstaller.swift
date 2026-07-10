import Foundation

enum AppInstaller {
    typealias Extractor = (URL, URL) -> Bool
    typealias Replacer = (FileManager, URL, URL, String) throws -> Void

    static func install(
        zipURL: URL,
        destinationURL: URL,
        fileManager: FileManager = .default,
        extractor: Extractor = extractZip,
        replacer: Replacer = replaceItem
    ) -> Bool {
        let parentDirectory = destinationURL.deletingLastPathComponent()
        let stagingDirectory = parentDirectory.appendingPathComponent(
            ".MonitorAgent-update-\(UUID().uuidString)",
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        } catch {
            return false
        }
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        guard extractor(zipURL, stagingDirectory) else { return false }

        let stagedApp = stagingDirectory.appendingPathComponent(
            destinationURL.lastPathComponent,
            isDirectory: true
        )
        guard isValidMonitorAgentApp(stagedApp, fileManager: fileManager) else { return false }

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                let backupName = ".MonitorAgent-backup-\(UUID().uuidString).app"
                let backupURL = parentDirectory.appendingPathComponent(backupName)
                do {
                    try replacer(fileManager, destinationURL, stagedApp, backupName)
                    guard isValidMonitorAgentApp(destinationURL, fileManager: fileManager) else {
                        restoreBackup(
                            backupURL,
                            destinationURL: destinationURL,
                            fileManager: fileManager
                        )
                        return false
                    }
                } catch {
                    restoreBackup(
                        backupURL,
                        destinationURL: destinationURL,
                        fileManager: fileManager
                    )
                    return false
                }
                try? fileManager.removeItem(at: backupURL)
            } else {
                try fileManager.moveItem(at: stagedApp, to: destinationURL)
            }
            return true
        } catch {
            return false
        }
    }

    private static func isValidMonitorAgentApp(_ appURL: URL, fileManager: FileManager) -> Bool {
        let contentsDirectory = appURL.appendingPathComponent("Contents", isDirectory: true)
        let infoURL = contentsDirectory.appendingPathComponent("Info.plist")
        let executableURL = contentsDirectory.appendingPathComponent("MacOS/MonitorAgent")

        guard
            let info = NSDictionary(contentsOf: infoURL),
            info["CFBundleIdentifier"] as? String == "com.hd1987.monitor-agent",
            info["CFBundleExecutable"] as? String == "MonitorAgent",
            info["CFBundlePackageType"] as? String == "APPL"
        else {
            return false
        }

        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: executableURL.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && fileManager.isExecutableFile(atPath: executableURL.path)
    }

    private static func replaceItem(
        fileManager: FileManager,
        destinationURL: URL,
        stagedAppURL: URL,
        backupName: String
    ) throws {
        _ = try fileManager.replaceItemAt(
            destinationURL,
            withItemAt: stagedAppURL,
            backupItemName: backupName,
            options: []
        )
    }

    private static func restoreBackup(
        _ backupURL: URL,
        destinationURL: URL,
        fileManager: FileManager
    ) {
        guard fileManager.fileExists(atPath: backupURL.path) else { return }
        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }
        try? fileManager.moveItem(at: backupURL, to: destinationURL)
    }

    private static func extractZip(_ zipURL: URL, to destinationURL: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, destinationURL.path]
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
