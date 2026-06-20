import SwiftUI

struct AboutView: View {
    private let repoURL = "https://github.com/hd1987/monitor-agent-app"

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 32)

            // App icon — use NSApp icon (reads AppIcon.icns from .app bundle)
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 128, height: 128)

            Spacer().frame(height: 20)

            Text("MonitorAgent")
                .font(.system(size: 22, weight: .bold))

            Spacer().frame(height: 6)

            Text("Usage statistics for Claude Code\nand Codex in your menu bar.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            Spacer().frame(height: 24)

            // Version
            HStack(spacing: 8) {
                Text("Version")
                    .foregroundStyle(.secondary)
                Text(AppVersion.display)
            }
            .font(.system(size: 13))

            Spacer().frame(height: 24)

            // GitHub button
            Button {
                if let url = URL(string: repoURL) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("GitHub")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 80, height: 30)
            }
            .buttonStyle(.bordered)

            Spacer().frame(height: 28)
        }
        .frame(width: 300)
    }
}

/// Reads the installed app version from the bundle created during release.
enum AppVersion {
    static var display: String {
        displayVersion(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    static var comparable: String? {
        comparableVersion(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    static func displayVersion(infoDictionary: [String: Any]) -> String {
        comparableVersion(infoDictionary: infoDictionary) ?? "Development"
    }

    static func comparableVersion(infoDictionary: [String: Any]) -> String? {
        guard let version = infoDictionary["CFBundleShortVersionString"] as? String else {
            return nil
        }

        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
