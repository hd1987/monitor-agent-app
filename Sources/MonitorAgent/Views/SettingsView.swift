import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager

    /// Local draft state — only committed on Save
    @State private var draftTheme: Theme = .system
    @State private var draftSyncInterval: SyncInterval = .thirty
    @State private var draftKeepInBackground: Bool = true
    @State private var draftLaunchAtLogin: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                GeneralSettingsView(
                    draftTheme: $draftTheme,
                    draftSyncInterval: $draftSyncInterval,
                    draftKeepInBackground: $draftKeepInBackground,
                    draftLaunchAtLogin: $draftLaunchAtLogin
                )
            }

            Divider()

            // Cancel / Save buttons
            HStack {
                Spacer()
                Button {
                    NSApp.keyWindow?.close()
                } label: {
                    Text("Cancel").frame(minWidth: 48)
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    themeManager.theme = draftTheme
                    SyncSettings.shared.interval = draftSyncInterval
                    SyncSettings.shared.keepInBackground = draftKeepInBackground
                    SyncSettings.shared.launchAtLogin = draftLaunchAtLogin
                    NSApp.keyWindow?.close()
                } label: {
                    Text("Save").frame(minWidth: 48)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 480, minHeight: 380)
        .onAppear {
            draftTheme = themeManager.theme
            draftSyncInterval = SyncSettings.shared.interval
            draftKeepInBackground = SyncSettings.shared.keepInBackground
            draftLaunchAtLogin = SyncSettings.shared.launchAtLogin
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Binding var draftTheme: Theme
    @Binding var draftSyncInterval: SyncInterval
    @Binding var draftKeepInBackground: Bool
    @Binding var draftLaunchAtLogin: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(
                title: "Theme",
                description: "Choose the appearance of the app. System follows your macOS settings."
            ) {
                Picker("", selection: $draftTheme) {
                    ForEach(Theme.allCases) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            Divider().padding(.vertical, 4)

            SettingsRow(
                title: "Sync Interval",
                description: "How often to sync usage data. \"Never\" syncs only when the panel is opened."
            ) {
                Picker("", selection: $draftSyncInterval) {
                    ForEach(SyncInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
                .frame(width: 100)
            }

            Divider().padding(.vertical, 4)

            SettingsRow(
                title: "Keep in Background",
                description: "Keep the app running when you press ⌘Q. Use right-click → Quit to fully exit."
            ) {
                Toggle("", isOn: $draftKeepInBackground)
                    .toggleStyle(.switch)
            }

            Divider().padding(.vertical, 4)

            SettingsRow(
                title: "Launch at Login",
                description: "Automatically start MonitorAgent when you log in."
            ) {
                Toggle("", isOn: $draftLaunchAtLogin)
                    .toggleStyle(.switch)
            }
        }
        .padding(20)
    }
}

// MARK: - Reusable Row

/// macOS Settings style row: title + description on left, control on right.
struct SettingsRow<Control: View>: View {
    let title: String
    let description: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control()
                .frame(alignment: .trailing)
        }
        .padding(.vertical, 12)
    }
}
