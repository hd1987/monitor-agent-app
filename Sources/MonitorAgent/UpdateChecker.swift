import AppKit
import Foundation
import SwiftUI

struct RestartCommand {
    let executablePath: String
    let arguments: [String]
}

enum RestartLauncher {
    static func makeCommand(appURL: URL, delay: TimeInterval) -> RestartCommand {
        let delayValue = String(format: "%.1f", delay)
        let appPath = shellQuoted(appURL.path)
        let launchScript = "/bin/sleep \(delayValue); /usr/bin/open -n \(appPath)"
        return RestartCommand(
            executablePath: "/bin/sh",
            arguments: [
                "-c",
                "/usr/bin/nohup /bin/sh -c \(shellQuoted(launchScript)) >/dev/null 2>&1 &"
            ]
        )
    }

    static func launch(_ command: RestartCommand) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        try process.run()
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// Checks GitHub Releases for new versions, downloads and installs updates.
final class UpdateChecker: NSObject, URLSessionDownloadDelegate {
    static let shared = UpdateChecker()

    private let repo = "hd1987/monitor-agent-app"
    private let lastCheckKey = "lastUpdateCheck"
    private var isChecking = false

    private var window: NSPanel?
    private var hostingView: NSHostingView<UpdateCheckView>?

    private var downloadTask: URLSessionDownloadTask?
    private var pendingRelease: Release?

    private override init() { super.init() }

    // MARK: - Public

    func checkForUpdates(silent: Bool) {
        guard currentVersion != nil else {
            if !silent {
                configureWindow(state: .unavailable())
            }
            return
        }

        if silent {
            guard !isChecking else { return }
            let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
            if let last, Date().timeIntervalSince(last) < 86400 { return }
        }

        isChecking = true
        if !silent { showChecking() }

        fetchLatestRelease { [weak self] result in
            DispatchQueue.main.async { self?.handleResult(result, silent: silent) }
        }
    }

    func checkOnLaunch() { checkForUpdates(silent: true) }

    /// Refresh window appearance to match current theme
    func applyTheme() {
        window?.appearance = ThemeManager.shared.nsAppearance
    }

    // MARK: - Result Handling

    private func handleResult(_ result: Result<Release?, Error>, silent: Bool) {
        isChecking = false
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)

        switch result {
        case .success(let release) where release != nil && isNewer(release!.version):
            pendingRelease = release
            configureWindow(
                state: .newVersion(
                    tagName: release!.tagName,
                    currentVersionWithCommit: AppVersion.versionWithCommit,
                    currentReleaseDate: AppVersion.releaseDate,
                    releaseBody: release!.body
                )
            )
        case .success:
            if silent { closeWindow(); return }
            configureWindow(
                state: .upToDate(
                    versionWithCommit: AppVersion.versionWithCommit,
                    releaseDate: AppVersion.releaseDate
                )
            )
        case .failure(let error):
            if silent { closeWindow(); return }
            configureWindow(state: .failure(title: "Update check failed", detail: error.localizedDescription))
        }
    }

    // MARK: - Window States

    private func showChecking() {
        configureWindow(state: .checking())
    }

    private func showDownloading(_ tagName: String) {
        configureWindow(state: .downloading(tagName: tagName))
    }

    private func showInstalling() {
        configureWindow(state: .installing())
    }

    // MARK: - Window Management

    private func configureWindow(state: UpdateCheckDialogState, activate: Bool = true) {
        if window == nil { createWindow() }

        hostingView?.rootView = UpdateCheckView(state: state) { [weak self] action in
            self?.perform(action)
        }

        if let fittingSize = hostingView?.fittingSize {
            window?.setContentSize(NSSize(width: max(460, fittingSize.width), height: fittingSize.height))
        }

        guard activate else { return }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createWindow() {
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        win.title = ""
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isReleasedWhenClosed = false
        win.level = .normal
        win.hidesOnDeactivate = false
        win.isMovableByWindowBackground = true

        win.appearance = ThemeManager.shared.nsAppearance

        let hosting = NSHostingView(
            rootView: UpdateCheckView(state: .checking()) { [weak self] action in
                self?.perform(action)
            }
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 260)
        hosting.autoresizingMask = [.width, .height]
        win.contentView = hosting

        window = win
        hostingView = hosting
    }

    private func perform(_ action: UpdateCheckDialogAction) {
        switch action {
        case .close:
            close()
        case .startDownload:
            startDownload()
        case .restartApp:
            restartApp()
        }
    }

    @objc private func close() {
        downloadTask?.cancel()
        downloadTask = nil
        isChecking = false
        closeWindow()
    }

    private func closeWindow() { window?.orderOut(nil) }

    // MARK: - Download

    @objc private func startDownload() {
        guard let release = pendingRelease else { return }
        showDownloading(release.tagName)

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        downloadTask = session.downloadTask(with: release.downloadURL)
        downloadTask?.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let mb = Double(totalBytesWritten) / 1_000_000
        let totalMb = Double(totalBytesExpectedToWrite) / 1_000_000
        DispatchQueue.main.async {
            self.configureWindow(
                state: .downloading(
                    tagName: self.pendingRelease?.tagName ?? "update",
                    fraction: fraction,
                    downloadedMegabytes: mb,
                    totalMegabytes: totalMb
                ),
                activate: false
            )
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("MonitorAgent-update.zip")
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.moveItem(at: location, to: tmp)
        DispatchQueue.main.async {
            self.downloadTask = nil
            self.install(zipURL: tmp)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        DispatchQueue.main.async {
            self.downloadTask = nil
            self.configureWindow(state: .failure(title: "Download failed", detail: error.localizedDescription))
        }
    }

    // MARK: - Install

    private func install(zipURL: URL) {
        showInstalling()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let success = Self.extractApp(from: zipURL)
            DispatchQueue.main.async {
                if success {
                    self.configureWindow(state: .updateComplete())
                } else {
                    self.configureWindow(state: .failure(title: "Install failed", detail: "Could not extract the update."))
                }
            }
        }
    }

    private static func extractApp(from zipURL: URL) -> Bool {
        AppInstaller.install(
            zipURL: zipURL,
            destinationURL: URL(fileURLWithPath: "/Applications/MonitorAgent.app")
        )
    }

    @objc private func restartApp() {
        closeWindow()
        let appURL = URL(fileURLWithPath: "/Applications/MonitorAgent.app")
        let command = RestartLauncher.makeCommand(appURL: appURL, delay: 0.5)
        do {
            try RestartLauncher.launch(command)
            // Guarantee the old instance exits before the relaunched app takes over.
            if let delegate = NSApplication.shared.delegate as? AppDelegate {
                delegate.forceTerminate()
            } else {
                ForceTermination.exitImmediately()
            }
        } catch {
            configureWindow(state: .failure(title: "Restart failed", detail: error.localizedDescription))
        }
    }

    // MARK: - GitHub API

    private struct Release {
        let version: String
        let tagName: String
        let body: String
        let downloadURL: URL
    }

    private func fetchLatestRelease(completion: @escaping (Result<Release?, Error>) -> Void) {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                completion(.success(nil)); return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else {
                completion(.failure(UpdateError.invalidResponse)); return
            }

            let body = json["body"] as? String ?? ""
            let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

            guard let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                  let urlStr = asset["browser_download_url"] as? String,
                  let downloadURL = URL(string: urlStr) else {
                completion(.failure(UpdateError.noAsset)); return
            }
            completion(.success(Release(version: version, tagName: tagName, body: body, downloadURL: downloadURL)))
        }.resume()
    }

    // MARK: - Version Comparison

    private var currentVersion: String? { AppVersion.comparable }

    private func isNewer(_ remote: String) -> Bool {
        VersionComparison.isRemoteVersionNewer(remote, than: currentVersion)
    }

    // MARK: - Errors

    private enum UpdateError: LocalizedError {
        case invalidResponse, noAsset
        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Could not parse GitHub release info."
            case .noAsset:         return "No downloadable asset found in the release."
            }
        }
    }
}

enum VersionComparison {
    static func isRemoteVersionNewer(_ remote: String, than current: String?) -> Bool {
        guard let current else { return false }

        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        guard !r.isEmpty, !c.isEmpty else { return false }

        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv != cv { return rv > cv }
        }
        return false
    }
}

enum UpdateCheckMessage {
    static func currentBuildDetail(versionWithCommit: String, releaseDate: String?) -> String {
        joined([
            "Current version: \(versionWithCommit)",
            releaseDate.map { "Released \($0)" }
        ])
    }

    static func upToDateDetail(versionWithCommit: String, releaseDate: String?) -> String {
        joined([
            "MonitorAgent \(versionWithCommit) is the latest version.",
            releaseDate.map { "Released \($0)" }
        ])
    }

    static func newVersionDetail(
        releaseBody: String,
        currentVersionWithCommit: String,
        currentReleaseDate: String?
    ) -> String {
        let currentBuildDetail = currentBuildDetail(
            versionWithCommit: currentVersionWithCommit,
            releaseDate: currentReleaseDate
        )
        let body = releaseBody.isEmpty ? "A new version is ready to download." : releaseBody
        return "\(currentBuildDetail)\n\n\(body)"
    }

    private static func joined(_ lines: [String?]) -> String {
        lines.compactMap { $0 }.joined(separator: "\n")
    }
}
