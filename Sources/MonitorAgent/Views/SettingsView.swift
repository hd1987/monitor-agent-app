import SwiftUI

// MARK: - Settings Category

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case config = "Config"
    case prompt = "Prompt"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .config: return "doc.text"
        case .prompt: return "text.bubble"
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager

    var initialCategory: SettingsCategory = .general

    @State private var selectedCategory: SettingsCategory = .general

    // General drafts
    @State private var draftTheme: Theme = .system
    @State private var draftSyncInterval: SyncInterval = .thirty
    @State private var draftKeepInBackground: Bool = true
    @State private var draftLaunchAtLogin: Bool = false

    // Config drafts
    @State private var claudeConfigText: String = ""
    @State private var codexConfigText: String = ""
    @State private var claudeConfigExists: Bool = false
    @State private var codexConfigExists: Bool = false

    // Prompt drafts
    @State private var claudePromptText: String = ""
    @State private var codexPromptText: String = ""
    @State private var claudePromptExists: Bool = false
    @State private var codexPromptExists: Bool = false

    // Tab selection for Config / Prompt
    @State private var configTab: AppSourceTab = .claude
    @State private var promptTab: AppSourceTab = .claude

    // Save error alert
    @State private var showSaveError: Bool = false
    @State private var saveErrorMessage: String = ""

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 2) {
                ForEach(SettingsCategory.allCases) { category in
                    SidebarItem(
                        title: category.rawValue,
                        icon: category.icon,
                        isSelected: selectedCategory == category
                    ) {
                        selectedCategory = category
                    }
                }
                Spacer()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .frame(width: 160)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))

            // Content area
            VStack(spacing: 0) {
                // Tab bar for Config / Prompt (outside ScrollView for reliable hit testing)
                if selectedCategory == .config || selectedCategory == .prompt {
                    AppSourceTabBar(
                        selection: selectedCategory == .config ? $configTab : $promptTab
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }

                // Content
                switch selectedCategory {
                case .general:
                    ScrollView {
                        GeneralSettingsView(
                            draftTheme: $draftTheme,
                            draftSyncInterval: $draftSyncInterval,
                            draftKeepInBackground: $draftKeepInBackground,
                            draftLaunchAtLogin: $draftLaunchAtLogin
                        )
                    }
                    .frame(maxWidth: .infinity)
                case .config:
                    TabbedFileEditorView(
                        claudeText: $claudeConfigText,
                        codexText: $codexConfigText,
                        claudeExists: claudeConfigExists,
                        codexExists: codexConfigExists,
                        claudePath: Self.claudeSettingsPath,
                        codexPath: Self.codexConfigPath,
                        selectedTab: $configTab
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .prompt:
                    TabbedFileEditorView(
                        claudeText: $claudePromptText,
                        codexText: $codexPromptText,
                        claudeExists: claudePromptExists,
                        codexExists: codexPromptExists,
                        claudePath: Self.claudePromptPath,
                        codexPath: Self.codexPromptPath,
                        selectedTab: $promptTab
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

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
                        saveCurrentCategory()
                    } label: {
                        Text("Save").frame(minWidth: 48)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .frame(minWidth: 680, minHeight: 460)
        .onAppear {
            selectedCategory = initialCategory
            loadCategory(initialCategory)
        }
        .onChange(of: selectedCategory) {
            loadCategory(selectedCategory)
        }
        .alert("Save Error", isPresented: $showSaveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage)
        }
    }

    // MARK: - Load / Save

    private func loadCategory(_ category: SettingsCategory) {
        switch category {
        case .general:
            draftTheme = themeManager.theme
            draftSyncInterval = SyncSettings.shared.interval
            draftKeepInBackground = SyncSettings.shared.keepInBackground
            draftLaunchAtLogin = SyncSettings.shared.launchAtLogin
        case .config:
            configTab = .claude
            loadFileContent(
                path: Self.claudeSettingsPath,
                into: $claudeConfigText,
                exists: $claudeConfigExists
            )
            loadFileContent(
                path: Self.codexConfigPath,
                into: $codexConfigText,
                exists: $codexConfigExists
            )
        case .prompt:
            promptTab = .claude
            loadFileContent(
                path: Self.claudePromptPath,
                into: $claudePromptText,
                exists: $claudePromptExists
            )
            loadFileContent(
                path: Self.codexPromptPath,
                into: $codexPromptText,
                exists: $codexPromptExists
            )
        }
    }

    private func saveCurrentCategory() {
        switch selectedCategory {
        case .general:
            themeManager.theme = draftTheme
            SyncSettings.shared.interval = draftSyncInterval
            SyncSettings.shared.keepInBackground = draftKeepInBackground
            SyncSettings.shared.launchAtLogin = draftLaunchAtLogin

        case .config:
            // Validate JSON before saving Claude settings
            if claudeConfigExists || !claudeConfigText.isEmpty {
                if let data = claudeConfigText.data(using: .utf8) {
                    do {
                        _ = try JSONSerialization.jsonObject(with: data)
                    } catch {
                        saveErrorMessage = "Invalid JSON in Claude Code settings:\n\(error.localizedDescription)"
                        showSaveError = true
                        return
                    }
                }
                if !writeFile(path: Self.claudeSettingsPath, content: claudeConfigText) { return }
            }
            if codexConfigExists || !codexConfigText.isEmpty {
                if !writeFile(path: Self.codexConfigPath, content: codexConfigText) { return }
            }

        case .prompt:
            if claudePromptExists || !claudePromptText.isEmpty {
                if !writeFile(path: Self.claudePromptPath, content: claudePromptText) { return }
            }
            if codexPromptExists || !codexPromptText.isEmpty {
                if !writeFile(path: Self.codexPromptPath, content: codexPromptText) { return }
            }
        }

        NSApp.keyWindow?.close()
    }

    // MARK: - File I/O Helpers

    private func loadFileContent(path: String, into text: Binding<String>, exists: Binding<Bool>) {
        let expanded = NSString(string: path).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded),
           let content = try? String(contentsOfFile: expanded, encoding: .utf8) {
            text.wrappedValue = content
            exists.wrappedValue = true
        } else {
            text.wrappedValue = ""
            exists.wrappedValue = false
        }
    }

    /// Write content to file, returns false and shows alert on failure.
    private func writeFile(path: String, content: String) -> Bool {
        let expanded = NSString(string: path).expandingTildeInPath
        do {
            try content.write(toFile: expanded, atomically: true, encoding: .utf8)
            return true
        } catch {
            saveErrorMessage = "Failed to write \(path):\n\(error.localizedDescription)"
            showSaveError = true
            return false
        }
    }

    // MARK: - File Paths

    static let claudeSettingsPath = "~/.claude/settings.json"
    static let codexConfigPath = "~/.codex/config.toml"
    static let claudePromptPath = "~/.claude/CLAUDE.md"
    static let codexPromptPath = "~/.codex/AGENTS.md"
}

// MARK: - Sidebar Item

struct SidebarItem: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .foregroundColor(isSelected ? .accentColor : .primary)
        }
        .buttonStyle(.plain)
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
                HStack(spacing: 0) {
                    ForEach(Theme.allCases) { theme in
                        HStack(spacing: 4) {
                            Image(systemName: theme.icon)
                                .font(.system(size: 11))
                            Text(theme.rawValue)
                                .font(.system(size: 12))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(draftTheme == theme ? Color.accentColor : Color.clear)
                        )
                        .foregroundColor(draftTheme == theme ? .white : .secondary)
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                        .onTapGesture { draftTheme = theme }
                    }
                }
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(nsColor: .separatorColor).opacity(0.2))
                )
                .frame(width: 240)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - App Source Tab

/// Tab selector for Claude Code / Codex within Config and Prompt categories.
enum AppSourceTab: String, CaseIterable, Identifiable {
    case claude = "Claude Code"
    case codex = "Codex"

    var id: String { rawValue }
}

/// Full-width segmented tab bar — macOS System Settings style (blue capsule for selected).
struct AppSourceTabBar: View {
    @Binding var selection: AppSourceTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppSourceTab.allCases) { tab in
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: selection == tab ? .medium : .regular))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selection == tab ? Color.accentColor : Color.clear)
                    )
                    .foregroundColor(selection == tab ? .white : .primary)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture {
                        selection = tab
                    }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .separatorColor).opacity(0.15))
        )
    }
}

// MARK: - Tabbed File Editor (shared by Config & Prompt)

/// Displays a file editor that switches between Claude / Codex based on the selected tab.
struct TabbedFileEditorView: View {
    @Binding var claudeText: String
    @Binding var codexText: String
    let claudeExists: Bool
    let codexExists: Bool
    let claudePath: String
    let codexPath: String
    @Binding var selectedTab: AppSourceTab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if selectedTab == .claude {
                FileEditorSection(
                    subtitle: claudePath,
                    text: $claudeText,
                    fileExists: claudeExists
                )
                .id(AppSourceTab.claude)
            } else {
                FileEditorSection(
                    subtitle: codexPath,
                    text: $codexText,
                    fileExists: codexExists
                )
                .id(AppSourceTab.codex)
            }
        }
        .padding(20)
    }
}

// MARK: - File Editor Section

struct FileEditorSection: View {
    let subtitle: String
    @Binding var text: String
    let fileExists: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if fileExists {
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text("File not found at \(subtitle)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
