import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @State private var selectedTab = "General"

    private let tabs = ["General"]

    var body: some View {
        ScrollView {
            GeneralSettingsView()
        }
        .frame(width: 500, height: 320)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(
                title: "Theme",
                description: "Choose the appearance of the app. System follows your macOS settings."
            ) {
                Picker("", selection: $themeManager.theme) {
                    ForEach(Theme.allCases) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
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
