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
                Text(AppVersion.current)
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

/// Single source of truth for app version — update alongside git tag at release
enum AppVersion {
    static let current = "0.2.2"
}
