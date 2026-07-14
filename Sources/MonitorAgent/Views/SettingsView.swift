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

    var saveConfirmationTitle: String {
        "Save \(rawValue) settings?"
    }

    var saveConfirmationMessage: String {
        "Apply changes to \(rawValue) settings."
    }

    var saveSuccessMessage: String {
        "\(rawValue) settings saved."
    }
}

enum SaveSuccessToastPlacement {
    static let alignment: Alignment = .top
    static let edge: Edge = .top
    static let padding: CGFloat = 16
}

enum SaveSuccessToastStyle {
    static let backgroundColorName = "green"
    static let backgroundColor = Color.green
}

enum SettingsWindowLayout {
    static let minimumWidth: CGFloat = 960
    static let minimumHeight: CGFloat = 680
}

enum UsageDataRebuildCopy {
    static let buttonTitle = "Rebuild Local Usage Data"
    static let description = "Rebuilds Monitor Agent's local usage database from Claude Code and Codex session logs. Original session logs and settings will not be changed."
    static let confirmationTitle = "Rebuild Local Usage Data?"
    static let confirmationMessage = "Monitor Agent will rebuild its local usage database from your Claude Code and Codex session logs. Your original logs and settings will not be changed.\n\nThe current database will remain in use unless the rebuild completes successfully."
    static let runningMessage = "Rebuilding local usage data..."
    static let successTitle = "Local usage data rebuilt successfully."
    static let failureTitle = "Rebuild failed. Your existing usage data was not changed."
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var store: AppStore

    var initialCategory: SettingsCategory = .general

    @State private var selectedCategory: SettingsCategory = .general

    // General drafts
    @State private var draftTheme: Theme = .system
    @State private var draftSyncInterval: SyncInterval = .thirty
    @State private var draftGlobalShortcut: GlobalShortcut?
    @State private var draftKeepInBackground: Bool = true
    @State private var draftLaunchAtLogin: Bool = false
    @State private var draftClaudeQuotaEnabled: Bool = true
    @State private var draftCodexQuotaEnabled: Bool = true
    @State private var draftQuotaRefreshInterval: QuotaRefreshInterval = .twoMinutes

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

    // Save alerts / toast
    @State private var showSaveError: Bool = false
    @State private var saveErrorMessage: String = ""
    @State private var showSaveConfirmation: Bool = false
    @State private var showSaveSuccess: Bool = false
    @State private var saveSuccessMessage: String = ""

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
                            draftGlobalShortcut: $draftGlobalShortcut,
                            draftKeepInBackground: $draftKeepInBackground,
                            draftLaunchAtLogin: $draftLaunchAtLogin,
                            draftClaudeQuotaEnabled: $draftClaudeQuotaEnabled,
                            draftCodexQuotaEnabled: $draftCodexQuotaEnabled,
                            draftQuotaRefreshInterval: $draftQuotaRefreshInterval
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
                        showSaveConfirmation = true
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
        .frame(
            minWidth: SettingsWindowLayout.minimumWidth,
            minHeight: SettingsWindowLayout.minimumHeight
        )
        .overlay(alignment: SaveSuccessToastPlacement.alignment) {
            if showSaveSuccess {
                Text(saveSuccessMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(SaveSuccessToastStyle.backgroundColor)
                    )
                    .padding(.top, SaveSuccessToastPlacement.padding)
                    .transition(.opacity.combined(with: .move(edge: SaveSuccessToastPlacement.edge)))
            }
        }
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
        .alert(selectedCategory.saveConfirmationTitle, isPresented: $showSaveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                saveCurrentCategory()
            }
        } message: {
            Text(selectedCategory.saveConfirmationMessage)
        }
    }

    // MARK: - Load / Save

    private func loadCategory(_ category: SettingsCategory) {
        switch category {
        case .general:
            draftTheme = themeManager.theme
            draftSyncInterval = SyncSettings.shared.interval
            draftGlobalShortcut = GlobalShortcutController.shared.shortcut
            draftKeepInBackground = SyncSettings.shared.keepInBackground
            draftLaunchAtLogin = SyncSettings.shared.launchAtLogin
            draftClaudeQuotaEnabled = QuotaSettings.shared.claudeEnabled
            draftCodexQuotaEnabled = QuotaSettings.shared.codexEnabled
            draftQuotaRefreshInterval = QuotaSettings.shared.refreshInterval
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
            do {
                try GlobalShortcutController.shared.updateShortcut(draftGlobalShortcut)
            } catch {
                saveErrorMessage = error.localizedDescription
                showSaveError = true
                return
            }
            themeManager.theme = draftTheme
            SyncSettings.shared.interval = draftSyncInterval
            SyncSettings.shared.keepInBackground = draftKeepInBackground
            SyncSettings.shared.launchAtLogin = draftLaunchAtLogin
            QuotaSettings.shared.claudeEnabled = draftClaudeQuotaEnabled
            QuotaSettings.shared.codexEnabled = draftCodexQuotaEnabled
            QuotaSettings.shared.refreshInterval = draftQuotaRefreshInterval
            store.quotaSettingsDidChange()

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

        showSaveSuccessToast()
    }

    private func showSaveSuccessToast() {
        saveSuccessMessage = selectedCategory.saveSuccessMessage
        withAnimation(.easeInOut(duration: 0.15)) {
            showSaveSuccess = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeInOut(duration: 0.15)) {
                showSaveSuccess = false
            }
        }
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
    @EnvironmentObject var store: AppStore

    @Binding var draftTheme: Theme
    @Binding var draftSyncInterval: SyncInterval
    @Binding var draftGlobalShortcut: GlobalShortcut?
    @Binding var draftKeepInBackground: Bool
    @Binding var draftLaunchAtLogin: Bool
    @Binding var draftClaudeQuotaEnabled: Bool
    @Binding var draftCodexQuotaEnabled: Bool
    @Binding var draftQuotaRefreshInterval: QuotaRefreshInterval
    @State private var showUsageDataRebuildSheet = false

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
                description: "How often to sync while the panel is open. \"Never\" syncs once when opened."
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
                title: "Global Shortcut",
                description: "Show or hide the main panel from any app. Requires at least one modifier key."
            ) {
                GlobalShortcutRecorder(shortcut: $draftGlobalShortcut)
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
                description: SyncSettings.shared.canControlLaunchAtLogin
                    ? "Automatically start MonitorAgent when you log in."
                    : "Available only when running MonitorAgent from the installed app."
            ) {
                Toggle("", isOn: $draftLaunchAtLogin)
                    .toggleStyle(.switch)
                    .disabled(!SyncSettings.shared.canControlLaunchAtLogin)
            }

            Divider().padding(.vertical, 4)

            QuotaSettingsGroup(
                claudeEnabled: $draftClaudeQuotaEnabled,
                codexEnabled: $draftCodexQuotaEnabled,
                refreshInterval: $draftQuotaRefreshInterval
            )

            Divider().padding(.vertical, 4)

            SettingsRow(
                title: "Data",
                description: UsageDataRebuildCopy.description
            ) {
                Button {
                    store.prepareUsageDataRebuild()
                    showUsageDataRebuildSheet = true
                } label: {
                    Text(UsageDataRebuildCopy.buttonTitle)
                        .font(.system(size: 12))
                    .frame(minWidth: 190)
                }
                .disabled(store.isRebuildingUsageData)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showUsageDataRebuildSheet) {
            UsageDataRebuildSheetView(isPresented: $showUsageDataRebuildSheet)
                .environmentObject(store)
                .interactiveDismissDisabled(store.isRebuildingUsageData)
        }
    }

}

struct GlobalShortcutRecorder: View {
    @Binding var shortcut: GlobalShortcut?
    @State private var isRecording = false
    @State private var eventMonitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                beginRecording()
            } label: {
                Text(buttonTitle)
                    .font(.system(size: 12))
                    .frame(minWidth: 150)
            }

            if shortcut != nil {
                Button {
                    shortcut = nil
                    stopRecording()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear global shortcut")
                .accessibilityLabel("Clear global shortcut")
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var buttonTitle: String {
        if isRecording { return "Press shortcut…" }
        return shortcut?.displayName ?? "Record Shortcut"
    }

    private func beginRecording() {
        stopRecording()
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if GlobalShortcut.isRecordingCancellation(event) {
                stopRecording()
                return nil
            }
            guard let recordedShortcut = GlobalShortcut.make(from: event) else {
                NSSound.beep()
                return nil
            }
            shortcut = recordedShortcut
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        isRecording = false
    }
}

enum QuotaSettingsCopy {
    static let title = "Subscription Quota"
    static let claudeTitle = "Claude Code"
    static let claudeDescription = "Show Claude Code subscription quota in the main panel."
    static let codexTitle = "Codex"
    static let codexDescription = "Show Codex subscription quota in the main panel."
    static let refreshIntervalTitle = "Refresh Interval"
    static let refreshIntervalDescription = "Refresh while the panel is open. \"Never\" refreshes once when opened."
}

private struct QuotaSettingsGroup: View {
    @Binding var claudeEnabled: Bool
    @Binding var codexEnabled: Bool
    @Binding var refreshInterval: QuotaRefreshInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(QuotaSettingsCopy.title)
                .font(.system(size: 13, weight: .semibold))

            VStack(spacing: 0) {
                quotaRow(
                    title: QuotaSettingsCopy.claudeTitle,
                    description: QuotaSettingsCopy.claudeDescription,
                    isOn: $claudeEnabled
                )
                Divider().padding(.leading, 12)
                quotaRow(
                    title: QuotaSettingsCopy.codexTitle,
                    description: QuotaSettingsCopy.codexDescription,
                    isOn: $codexEnabled
                )
                Divider().padding(.leading, 12)
                HStack(spacing: 16) {
                    settingLabel(
                        title: QuotaSettingsCopy.refreshIntervalTitle,
                        description: QuotaSettingsCopy.refreshIntervalDescription
                    )
                    Spacer(minLength: 16)
                    Picker("", selection: $refreshInterval) {
                        ForEach(QuotaRefreshInterval.allCases) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                    .frame(width: 100)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(Color(nsColor: .separatorColor).opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quotaRow(
        title: String,
        description: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 16) {
            settingLabel(title: title, description: description)
            Spacer(minLength: 16)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func settingLabel(title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

struct UsageDataRebuildSheetView: View {
    @EnvironmentObject var store: AppStore
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            content
            actions
        }
        .padding(22)
        .frame(width: 430)
    }

    @ViewBuilder
    private var header: some View {
        if store.isRebuildingUsageData {
            Label(UsageDataRebuildCopy.runningMessage, systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .semibold))
        } else if store.usageDataRebuildSummary != nil {
            Label(UsageDataRebuildCopy.successTitle, systemImage: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
        } else if store.usageDataRebuildErrorMessage != nil {
            Label(UsageDataRebuildCopy.failureTitle, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
        } else {
            Label(UsageDataRebuildCopy.confirmationTitle, systemImage: "externaldrive.badge.timemachine")
                .font(.system(size: 15, weight: .semibold))
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isRebuildingUsageData {
            UsageDataRebuildProgressView(progress: store.usageDataRebuildProgress)
        } else if let summary = store.usageDataRebuildSummary {
            Text(summary.displayText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let message = store.usageDataRebuildErrorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your existing usage data was not changed.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(UsageDataRebuildCopy.confirmationMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack {
            Spacer()
            if store.isRebuildingUsageData {
                Button("Close") {}
                    .disabled(true)
            } else if store.usageDataRebuildSummary != nil || store.usageDataRebuildErrorMessage != nil {
                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", role: .cancel) {
                    isPresented = false
                }
                Button("Rebuild") {
                    store.rebuildLocalUsageData()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct UsageDataRebuildProgressView: View {
    let progress: SessionSyncProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: progress?.fractionCompleted ?? 0)
                .progressViewStyle(.linear)

            HStack {
                Text(fileProgressText)
                Spacer()
                Text(recordProgressText)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private var fileProgressText: String {
        guard let progress else { return "Preparing files..." }
        return "\(progress.completedFiles) / \(progress.totalFiles) files"
    }

    private var recordProgressText: String {
        guard let progress else { return "0 requests rebuilt" }
        let label = progress.recordsSynced == 1 ? "request" : "requests"
        return "\(progress.recordsSynced) \(label) rebuilt"
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
