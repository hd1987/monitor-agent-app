import SwiftUI

enum UpdateCheckDialogAction: Equatable {
    case close
    case startDownload
    case restartApp
}

struct UpdateCheckDialogButton: Equatable {
    let title: String
    let action: UpdateCheckDialogAction
    var isProminent = false
}

enum UpdateCheckDialogProgress: Equatable {
    case none
    case indeterminate
    case determinate(Double)
}

struct UpdateCheckDialogState: Equatable {
    let title: String
    var subtitle: String?
    var detail: String?
    var releaseNotesTitle: String?
    var releaseNotes: String?
    var progress: UpdateCheckDialogProgress = .none
    var primaryButton: UpdateCheckDialogButton?
    var secondaryButton: UpdateCheckDialogButton?
    var iconName: String = "arrow.down.circle"

    static func checking() -> UpdateCheckDialogState {
        UpdateCheckDialogState(
            title: "Checking for updates",
            detail: "Contacting GitHub Releases...",
            progress: .indeterminate,
            secondaryButton: UpdateCheckDialogButton(title: "Cancel", action: .close),
            iconName: "arrow.clockwise.circle"
        )
    }

    static func unavailable() -> UpdateCheckDialogState {
        UpdateCheckDialogState(
            title: "Update check unavailable",
            detail: "Update checks are available for installed app builds only.",
            primaryButton: UpdateCheckDialogButton(title: "OK", action: .close, isProminent: true),
            iconName: "exclamationmark.triangle"
        )
    }

    static func upToDate(versionWithCommit: String, releaseDate: String?) -> UpdateCheckDialogState {
        UpdateCheckDialogState(
            title: "You're up to date",
            subtitle: "MonitorAgent \(versionWithCommit)",
            detail: releaseDate.map { "Released \($0)" },
            primaryButton: UpdateCheckDialogButton(title: "OK", action: .close, isProminent: true),
            iconName: "checkmark.circle"
        )
    }

    static func newVersion(
        tagName: String,
        currentVersionWithCommit: String,
        currentReleaseDate: String?,
        releaseBody: String
    ) -> UpdateCheckDialogState {
        let metadata = UpdateCheckMessage.currentBuildDetail(
            versionWithCommit: currentVersionWithCommit,
            releaseDate: currentReleaseDate
        )
        return UpdateCheckDialogState(
            title: "New version available",
            subtitle: "\(tagName) is ready to install.",
            detail: metadata,
            releaseNotesTitle: "Release Notes",
            releaseNotes: releaseBody.isEmpty ? "A new version is ready to download." : releaseBody,
            primaryButton: UpdateCheckDialogButton(title: "Update", action: .startDownload, isProminent: true),
            secondaryButton: UpdateCheckDialogButton(title: "Later", action: .close),
            iconName: "sparkles"
        )
    }

    static func downloading(
        tagName: String,
        fraction: Double = 0,
        downloadedMegabytes: Double? = nil,
        totalMegabytes: Double? = nil
    ) -> UpdateCheckDialogState {
        let detail: String?
        if let downloadedMegabytes, let totalMegabytes {
            detail = String(format: "%.1f / %.1f MB", downloadedMegabytes, totalMegabytes)
        } else {
            detail = "Preparing download..."
        }

        return UpdateCheckDialogState(
            title: "Downloading \(tagName)",
            detail: detail,
            progress: .determinate(min(max(fraction, 0), 1)),
            secondaryButton: UpdateCheckDialogButton(title: "Cancel", action: .close),
            iconName: "arrow.down.circle"
        )
    }

    static func installing() -> UpdateCheckDialogState {
        UpdateCheckDialogState(
            title: "Installing update",
            detail: "Replacing the installed app...",
            progress: .indeterminate,
            iconName: "shippingbox"
        )
    }

    static func updateComplete() -> UpdateCheckDialogState {
        UpdateCheckDialogState(
            title: "Update complete",
            detail: "Restart to apply the update.",
            primaryButton: UpdateCheckDialogButton(title: "Restart", action: .restartApp, isProminent: true),
            secondaryButton: UpdateCheckDialogButton(title: "Later", action: .close),
            iconName: "checkmark.circle"
        )
    }

    static func failure(title: String, detail: String) -> UpdateCheckDialogState {
        UpdateCheckDialogState(
            title: title,
            detail: detail,
            primaryButton: UpdateCheckDialogButton(title: "OK", action: .close, isProminent: true),
            iconName: "exclamationmark.triangle"
        )
    }
}

struct UpdateCheckView: View {
    let state: UpdateCheckDialogState
    let perform: (UpdateCheckDialogAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: state.iconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 38, height: 38)
                    .background(iconColor.opacity(0.12))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 5) {
                    Text(state.title)
                        .font(.system(size: 16, weight: .semibold))
                    if let subtitle = state.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let detail = state.detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .utilityWindowGroupedSurface()
            }

            progressView

            if let releaseNotes = state.releaseNotes {
                VStack(alignment: .leading, spacing: 6) {
                    Text(state.releaseNotesTitle ?? "Details")
                        .font(.system(size: 12, weight: .semibold))
                    ScrollView {
                        Text(releaseNotes)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 118)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: UtilityWindowDesign.compactCornerRadius,
                            style: .continuous
                        )
                    )
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: UtilityWindowDesign.compactCornerRadius,
                            style: .continuous
                        )
                        .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
                    )
                }
            }

            HStack {
                Spacer()
                if let secondary = state.secondaryButton {
                    Button(secondary.title) {
                        perform(secondary.action)
                    }
                    .keyboardShortcut(.cancelAction)
                }
                if let primary = state.primaryButton {
                    if primary.isProminent {
                        Button(primary.title) {
                            perform(primary.action)
                        }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button(primary.title) {
                            perform(primary.action)
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 460)
        .utilityWindowBackground()
    }

    @ViewBuilder
    private var progressView: some View {
        switch state.progress {
        case .none:
            EmptyView()
        case .indeterminate:
            ProgressView()
                .progressViewStyle(.linear)
        case .determinate(let fraction):
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
        }
    }

    private var iconColor: Color {
        switch state.iconName {
        case "checkmark.circle":
            return .green
        case "exclamationmark.triangle":
            return .orange
        case "sparkles":
            return .accentColor
        default:
            return .secondary
        }
    }
}
