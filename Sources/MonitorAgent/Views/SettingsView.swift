import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager

    /// Local draft state — only committed on Save
    @State private var draftTheme: Theme = .system
    @State private var draftSyncInterval: SyncInterval = .thirty

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                GeneralSettingsView(
                    draftTheme: $draftTheme,
                    draftSyncInterval: $draftSyncInterval
                )
            }

            Divider()

            // Cancel / Save buttons
            HStack {
                Spacer()
                Button("Cancel") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    themeManager.theme = draftTheme
                    SyncSettings.shared.interval = draftSyncInterval
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 500, height: 320)
        .onAppear {
            draftTheme = themeManager.theme
            draftSyncInterval = SyncSettings.shared.interval
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Binding var draftTheme: Theme
    @Binding var draftSyncInterval: SyncInterval

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
