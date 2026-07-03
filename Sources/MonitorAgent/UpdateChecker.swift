import AppKit
import Foundation

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

    // UI elements (lazy-created, reused across states)
    private var window: NSPanel?
    private var titleLabel: NSTextField?
    private var detailLabel: NSTextField?
    private var progress: NSProgressIndicator?
    private var primaryBtn: NSButton?
    private var secondaryBtn: NSButton?

    private var downloadTask: URLSessionDownloadTask?
    private var pendingRelease: Release?

    private override init() { super.init() }

    // MARK: - Public

    func checkForUpdates(silent: Bool) {
        guard currentVersion != nil else {
            if !silent {
                showResult(
                    title: "Update check unavailable",
                    detail: "Update checks are available for installed app builds only.",
                    primary: ("OK", #selector(close))
                )
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
            showResult(
                title: "New version \(release!.tagName) available",
                detail: UpdateCheckMessage.newVersionDetail(
                    releaseBody: release!.body,
                    currentVersionWithCommit: AppVersion.versionWithCommit,
                    currentReleaseDate: AppVersion.releaseDate
                ),
                primary: ("Update", #selector(startDownload)),
                secondary: ("Later", #selector(close))
            )
        case .success:
            if silent { closeWindow(); return }
            showResult(
                title: "You're up to date",
                detail: UpdateCheckMessage.upToDateDetail(
                    versionWithCommit: AppVersion.versionWithCommit,
                    releaseDate: AppVersion.releaseDate
                ),
                primary: ("OK", #selector(close))
            )
        case .failure(let error):
            if silent { closeWindow(); return }
            showResult(
                title: "Update check failed",
                detail: error.localizedDescription,
                primary: ("OK", #selector(close))
            )
        }
    }

    // MARK: - Window States

    private func showChecking() {
        configureWindow(
            title: "Checking for updates...",
            showProgress: true, indeterminate: true,
            secondary: ("Cancel", #selector(close))
        )
    }

    private func showResult(
        title: String, detail: String = "",
        primary: (String, Selector)? = nil,
        secondary: (String, Selector)? = nil
    ) {
        configureWindow(
            title: title, detail: detail,
            showProgress: false,
            primary: primary, secondary: secondary
        )
    }

    private func showDownloading(_ tagName: String) {
        configureWindow(
            title: "Downloading \(tagName)...",
            showProgress: true, indeterminate: false,
            secondary: ("Cancel", #selector(close))
        )
    }

    private func showInstalling() {
        configureWindow(
            title: "Installing update...",
            showProgress: true, indeterminate: true
        )
    }

    // MARK: - Window Management

    private func configureWindow(
        title: String, detail: String = "",
        showProgress: Bool, indeterminate: Bool = false,
        primary: (String, Selector)? = nil,
        secondary: (String, Selector)? = nil
    ) {
        if window == nil { createWindow() }

        titleLabel?.stringValue = title
        detailLabel?.stringValue = detail
        detailLabel?.isHidden = detail.isEmpty

        progress?.isHidden = !showProgress
        if showProgress {
            progress?.isIndeterminate = indeterminate
            if indeterminate { progress?.startAnimation(nil) }
            else { progress?.doubleValue = 0 }
        }

        configureButton(primaryBtn, spec: primary, accent: true)
        configureButton(secondaryBtn, spec: secondary)

        // Reset secondary button position based on whether primary is visible
        let winW = window?.frame.width ?? 380
        if primary == nil && secondary != nil {
            secondaryBtn?.frame.origin.x = winW - 100
        } else {
            secondaryBtn?.frame.origin.x = winW - 190
        }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureButton(_ button: NSButton?, spec: (String, Selector)?, accent: Bool = false) {
        guard let button else { return }
        if let (label, action) = spec {
            button.action = action
            button.isHidden = false
            if accent {
                button.bezelColor = .controlAccentColor
                button.attributedTitle = NSAttributedString(
                    string: label,
                    attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13)]
                )
            } else {
                button.bezelColor = nil
                button.title = label
            }
        } else {
            button.isHidden = true
        }
    }

    private func createWindow() {
        let w: CGFloat = 420, h: CGFloat = 210

        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        win.title = ""
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.hidesOnDeactivate = false
        win.isMovableByWindowBackground = true

        win.appearance = ThemeManager.shared.nsAppearance

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        win.contentView = container

        titleLabel = makeLabel(in: container, frame: .init(x: 20, y: 170, width: w - 40, height: 20),
                               font: .boldSystemFont(ofSize: 13))
        detailLabel = makeLabel(in: container, frame: .init(x: 20, y: 70, width: w - 40, height: 82),
                                font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        detailLabel?.lineBreakMode = .byWordWrapping
        detailLabel?.maximumNumberOfLines = 0

        let indicator = NSProgressIndicator(frame: NSRect(x: 20, y: 58, width: w - 40, height: 20))
        indicator.style = .bar
        container.addSubview(indicator)
        progress = indicator

        primaryBtn = makeButton(in: container, frame: .init(x: w - 100, y: 15, width: 80, height: 30),
                                keyEquivalent: "\r")
        secondaryBtn = makeButton(in: container, frame: .init(x: w - 190, y: 15, width: 80, height: 30),
                                  keyEquivalent: "\u{1b}")

        window = win
    }

    private func makeLabel(in parent: NSView, frame: NSRect,
                           font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = color
        label.frame = frame
        parent.addSubview(label)
        return label
    }

    private func makeButton(in parent: NSView, frame: NSRect, keyEquivalent: String) -> NSButton {
        let btn = NSButton(title: "", target: self, action: nil)
        btn.bezelStyle = .rounded
        btn.frame = frame
        btn.keyEquivalent = keyEquivalent
        btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        parent.addSubview(btn)
        return btn
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
            self.detailLabel?.stringValue = String(format: "%.1f / %.1f MB", mb, totalMb)
            self.detailLabel?.isHidden = false
            self.progress?.doubleValue = fraction * 100
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
            self.showResult(title: "Download failed", detail: error.localizedDescription,
                            primary: ("OK", #selector(self.close)))
        }
    }

    // MARK: - Install

    private func install(zipURL: URL) {
        showInstalling()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let success = Self.extractApp(from: zipURL)
            DispatchQueue.main.async {
                if success {
                    self.showResult(title: "Update complete", detail: "Restart to apply the update.",
                                    primary: ("Restart", #selector(self.restartApp)),
                                    secondary: ("Later", #selector(self.close)))
                } else {
                    self.showResult(title: "Install failed", detail: "Could not extract the update.",
                                    primary: ("OK", #selector(self.close)))
                }
            }
        }
    }

    private static func extractApp(from zipURL: URL) -> Bool {
        let appPath = "/Applications/MonitorAgent.app"
        try? FileManager.default.removeItem(atPath: appPath)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-xk", zipURL.path, "/Applications/"]
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    @objc private func restartApp() {
        closeWindow()
        let appURL = URL(fileURLWithPath: "/Applications/MonitorAgent.app")
        let command = RestartLauncher.makeCommand(appURL: appURL, delay: 0.5)
        do {
            try RestartLauncher.launch(command)
            // Force quit to bypass keepInBackground cancellation
            if let delegate = NSApplication.shared.delegate as? AppDelegate {
                delegate.forceTerminate()
            } else {
                ForceTermination.exitImmediately()
            }
        } catch {
            showResult(title: "Restart failed", detail: error.localizedDescription,
                       primary: ("OK", #selector(close)))
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
        let currentBuildDetail = joined([
            "Current version: \(currentVersionWithCommit)",
            currentReleaseDate.map { "Released \($0)" }
        ])
        let body = releaseBody.isEmpty ? "A new version is ready to download." : releaseBody
        return "\(currentBuildDetail)\n\n\(body)"
    }

    private static func joined(_ lines: [String?]) -> String {
        lines.compactMap { $0 }.joined(separator: "\n")
    }
}
