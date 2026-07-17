import SwiftUI

struct AboutView: View {
    private let repoURL = "https://github.com/hd1987/monitor-agent-app"

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)

            VStack(spacing: 6) {
                Text("MonitorAgent")
                    .font(.system(size: 22, weight: .bold))

                Text("Usage statistics for Claude Code and Codex in your menu bar.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 250)
            }

            VStack(spacing: 6) {
                Text("Version: \(AppVersion.versionWithCommit)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))

                if let releaseDate = AppVersion.releaseDate {
                    Text("Released \(releaseDate)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .utilityWindowGroupedSurface()

            Button {
                if let url = URL(string: repoURL) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("GitHub", systemImage: "arrow.up.right")
                    .font(.system(size: 13, weight: .medium))
                    .frame(minWidth: 90, minHeight: 28)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
        .frame(width: 320)
        .utilityWindowBackground()
    }
}

/// Reads the installed app version from the bundle created during release.
enum AppVersion {
    private static let commitKey = "MonitorAgentGitCommit"
    private static let releaseDateKey = "MonitorAgentReleaseDate"

    static var display: String {
        displayVersion(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    static var versionWithCommit: String {
        versionWithCommitDisplay(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    static var releaseDate: String? {
        releaseDateDisplay(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    static var comparable: String? {
        comparableVersion(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    static func displayVersion(infoDictionary: [String: Any]) -> String {
        comparableVersion(infoDictionary: infoDictionary) ?? "Development"
    }

    static func versionWithCommitDisplay(infoDictionary: [String: Any]) -> String {
        let version = displayVersion(infoDictionary: infoDictionary)
        guard let commit = trimmedString(commitKey, in: infoDictionary) else {
            return version
        }

        return "\(version) (\(commit))"
    }

    static func releaseDateDisplay(infoDictionary: [String: Any]) -> String? {
        guard let rawDate = trimmedString(releaseDateKey, in: infoDictionary) else {
            return nil
        }

        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"

        guard let date = parser.date(from: rawDate) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    static func comparableVersion(infoDictionary: [String: Any]) -> String? {
        guard let version = infoDictionary["CFBundleShortVersionString"] as? String else {
            return nil
        }

        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func trimmedString(_ key: String, in infoDictionary: [String: Any]) -> String? {
        guard let value = infoDictionary[key] as? String else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
