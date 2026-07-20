import SwiftUI

// MARK: - Settings Category

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case extensions = "Extensions"
    case config = "Config"
    case prompt = "Prompt"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .extensions: return "puzzlepiece.extension"
        case .config: return "doc.text"
        case .prompt: return "text.bubble"
        }
    }

    var isReadOnly: Bool {
        self == .extensions
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

enum SaveSuccessIndicatorStyle {
    static let systemImage = "checkmark.circle.fill"
}

enum SettingsSavePolicy {
    static func isEnabled(
        for category: SettingsCategory,
        allowsExternalConfigSaving: Bool
    ) -> Bool {
        switch category {
        case .general:
            return true
        case .extensions:
            return false
        case .config, .prompt:
            return allowsExternalConfigSaving
        }
    }
}

enum GlobalShortcutSettingsCopy {
    static let enabledDescription = "Show or hide the main panel from any app. Requires at least one modifier key."
    static let developmentDisabledDescription = "Available only when running MonitorAgent from the installed app."
}

enum SettingsWindowLayout {
    static let defaultWidth: CGFloat = 820
    static let defaultHeight: CGFloat = 600
    static let minimumWidth: CGFloat = 760
    static let minimumHeight: CGFloat = 520
    static let sidebarVisibility: NavigationSplitViewVisibility = .all
    static let contentTopPadding: CGFloat = 0
    static let groupedFormTopPadding: CGFloat = -20
}

enum UsageDataRebuildCopy {
    static let buttonTitle = "Rebuild Local Usage Data"
    static let description = "Rebuilds Monitor Agent's local usage database from Claude Code and Codex session logs. Original session logs and settings will not be changed."
    static let confirmationTitle = "Rebuild Local Usage Data?"
    static let confirmationMessage = "Monitor Agent will rebuild its local usage database from your Claude Code and Codex session logs. Your original logs and settings will not be changed.\n\nClaude Code and Codex can continue running during the rebuild. New activity will be synchronized before completion.\n\nThe current database will remain in use unless the rebuild completes successfully."
    static let runningMessage = "Rebuilding local usage data..."
    static let successTitle = "Local usage data rebuilt successfully."
    static let failureTitle = "Rebuild failed. Your existing usage data was not changed."
    static let canceledTitle = "Rebuild canceled."
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isSidebarFocused: Bool
    private let allowsGlobalShortcutRegistration = RuntimeEnvironment.current.featurePolicy.allowsGlobalShortcutRegistration
    private let allowsExternalConfigSaving = RuntimeEnvironment.current.featurePolicy.allowsExternalConfigSaving

    @State private var selectedCategory: SettingsCategory

    // General drafts
    @State private var draftTheme: Theme = .system
    @State private var draftSyncInterval: SyncInterval = .thirty
    @State private var draftGlobalShortcut: GlobalShortcut?
    @State private var draftLaunchAtLogin: Bool = false
    @State private var draftClaudeQuotaEnabled: Bool = true
    @State private var draftCodexQuotaEnabled: Bool = true
    @State private var draftClaudeExpirationDate: Date?
    @State private var draftCodexExpirationDate: Date?
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

    // Tab selection for Extensions, Config, and Prompt
    @State private var extensionsTab: AppSourceTab = .claude
    @State private var configTab: AppSourceTab = .claude
    @State private var promptTab: AppSourceTab = .claude

    // Extension inventory
    @State private var claudeExtensionInventory: ExtensionInventory = .empty
    @State private var codexExtensionInventory: ExtensionInventory = .empty
    @State private var isLoadingExtensionInventories = false
    @State private var extensionInventoryLoadID = UUID()

    // Save alerts / toast
    @State private var showSaveError: Bool = false
    @State private var saveErrorMessage: String = ""
    @State private var showSaveConfirmation: Bool = false
    @State private var showSaveSuccess: Bool = false
    @State private var saveSuccessMessage: String = ""

    init(initialCategory: SettingsCategory = .general) {
        _selectedCategory = State(initialValue: initialCategory)
    }

    var body: some View {
        NavigationSplitView(
            columnVisibility: .constant(SettingsWindowLayout.sidebarVisibility)
        ) {
            List(selection: sidebarSelection) {
                ForEach(SettingsCategory.allCases) { category in
                    Label(category.rawValue, systemImage: category.icon)
                        .tag(category)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 190)
            .focused($isSidebarFocused)
        } detail: {
            VStack(spacing: 0) {
                settingsContent

                HStack {
                    if showSaveSuccess {
                        Label(
                            saveSuccessMessage,
                            systemImage: SaveSuccessIndicatorStyle.systemImage
                        )
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                    }
                    Spacer()
                    if selectedCategory.isReadOnly {
                        Button {
                            NSApp.keyWindow?.close()
                        } label: {
                            Text("Close").frame(minWidth: 48)
                        }
                        .keyboardShortcut(.cancelAction)

                        Button {
                            loadExtensionInventories()
                        } label: {
                            Text("Refresh").frame(minWidth: 58)
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isLoadingExtensionInventories)
                    } else {
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
                        .disabled(!isCurrentCategorySaveEnabled)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: SettingsWindowLayout.minimumWidth,
            minHeight: SettingsWindowLayout.minimumHeight
        )
        .onAppear {
            loadCategory(selectedCategory)
            isSidebarFocused = true
        }
        .onChange(of: selectedCategory) {
            showSaveSuccess = false
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

    private var sidebarSelection: Binding<SettingsCategory?> {
        Binding(
            get: { selectedCategory },
            set: { category in
                if let category {
                    selectedCategory = category
                }
            }
        )
    }

    private var isCurrentCategorySaveEnabled: Bool {
        SettingsSavePolicy.isEnabled(
            for: selectedCategory,
            allowsExternalConfigSaving: allowsExternalConfigSaving
        )
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch selectedCategory {
        case .general:
            GeneralSettingsView(
                draftTheme: $draftTheme,
                draftSyncInterval: $draftSyncInterval,
                draftGlobalShortcut: $draftGlobalShortcut,
                draftLaunchAtLogin: $draftLaunchAtLogin,
                draftClaudeQuotaEnabled: $draftClaudeQuotaEnabled,
                draftCodexQuotaEnabled: $draftCodexQuotaEnabled,
                draftClaudeExpirationDate: $draftClaudeExpirationDate,
                draftCodexExpirationDate: $draftCodexExpirationDate,
                draftQuotaRefreshInterval: $draftQuotaRefreshInterval,
                allowsGlobalShortcutRegistration: allowsGlobalShortcutRegistration
            )
        case .extensions:
            ExtensionsSettingsView(
                selectedTab: $extensionsTab,
                inventory: extensionsTab == .claude
                    ? claudeExtensionInventory
                    : codexExtensionInventory,
                isLoading: isLoadingExtensionInventories
            )
        case .config:
            VStack(spacing: 0) {
                AppSourceTabBar(selection: $configTab)
                    .padding(.top, SettingsWindowLayout.contentTopPadding)
                TabbedFileEditorView(
                    claudeText: $claudeConfigText,
                    codexText: $codexConfigText,
                    claudeExists: claudeConfigExists,
                    codexExists: codexConfigExists,
                    claudePath: Self.claudeSettingsPath,
                    codexPath: Self.codexConfigPath,
                    selectedTab: $configTab
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .prompt:
            VStack(spacing: 0) {
                AppSourceTabBar(selection: $promptTab)
                    .padding(.top, SettingsWindowLayout.contentTopPadding)
                TabbedFileEditorView(
                    claudeText: $claudePromptText,
                    codexText: $codexPromptText,
                    claudeExists: claudePromptExists,
                    codexExists: codexPromptExists,
                    claudePath: Self.claudePromptPath,
                    codexPath: Self.codexPromptPath,
                    selectedTab: $promptTab
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Load / Save

    private func loadCategory(_ category: SettingsCategory) {
        switch category {
        case .general:
            draftTheme = themeManager.theme
            draftSyncInterval = SyncSettings.shared.interval
            draftGlobalShortcut = GlobalShortcutController.shared.shortcut
            draftLaunchAtLogin = SyncSettings.shared.launchAtLogin
            draftClaudeQuotaEnabled = QuotaSettings.shared.claudeEnabled
            draftCodexQuotaEnabled = QuotaSettings.shared.codexEnabled
            draftClaudeExpirationDate = QuotaSettings.shared.claudeExpirationDate
            draftCodexExpirationDate = QuotaSettings.shared.codexExpirationDate
            draftQuotaRefreshInterval = QuotaSettings.shared.refreshInterval
        case .extensions:
            extensionsTab = .claude
            loadExtensionInventories()
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
            if allowsGlobalShortcutRegistration {
                do {
                    try GlobalShortcutController.shared.updateShortcut(draftGlobalShortcut)
                } catch {
                    saveErrorMessage = error.localizedDescription
                    showSaveError = true
                    return
                }
            }
            themeManager.theme = draftTheme
            SyncSettings.shared.interval = draftSyncInterval
            SyncSettings.shared.launchAtLogin = draftLaunchAtLogin
            QuotaSettings.shared.claudeEnabled = draftClaudeQuotaEnabled
            QuotaSettings.shared.codexEnabled = draftCodexQuotaEnabled
            QuotaSettings.shared.claudeExpirationDate = draftClaudeExpirationDate
            QuotaSettings.shared.codexExpirationDate = draftCodexExpirationDate
            QuotaSettings.shared.refreshInterval = draftQuotaRefreshInterval
            store.quotaSettingsDidChange()

        case .extensions:
            return

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

        showSaveSuccessIndicator()
    }

    private func showSaveSuccessIndicator() {
        saveSuccessMessage = selectedCategory.saveSuccessMessage
        withAnimation(UtilityWindowDesign.presentation(reduceMotion: reduceMotion)) {
            showSaveSuccess = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(UtilityWindowDesign.presentation(reduceMotion: reduceMotion)) {
                showSaveSuccess = false
            }
        }
    }

    private func loadExtensionInventories() {
        let loadID = UUID()
        extensionInventoryLoadID = loadID
        isLoadingExtensionInventories = true
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        Task.detached(priority: .userInitiated) {
            let loader = ExtensionInventoryLoader()
            let claudeInventory = loader.load(source: .claude, homeDirectory: homeDirectory)
            let codexInventory = loader.load(source: .codex, homeDirectory: homeDirectory)
            await MainActor.run {
                guard extensionInventoryLoadID == loadID else { return }
                claudeExtensionInventory = claudeInventory
                codexExtensionInventory = codexInventory
                isLoadingExtensionInventories = false
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

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject var store: AppStore

    @Binding var draftTheme: Theme
    @Binding var draftSyncInterval: SyncInterval
    @Binding var draftGlobalShortcut: GlobalShortcut?
    @Binding var draftLaunchAtLogin: Bool
    @Binding var draftClaudeQuotaEnabled: Bool
    @Binding var draftCodexQuotaEnabled: Bool
    @Binding var draftClaudeExpirationDate: Date?
    @Binding var draftCodexExpirationDate: Date?
    @Binding var draftQuotaRefreshInterval: QuotaRefreshInterval
    let allowsGlobalShortcutRegistration: Bool
    @State private var showUsageDataRebuildSheet = false

    var body: some View {
        Form {
            Section {
                SettingsRow(
                    title: "Theme",
                    description: "Choose the appearance of the app. System follows your macOS settings."
                ) {
                    Picker("Theme", selection: $draftTheme) {
                        ForEach(Theme.allCases) { theme in
                            Label(theme.rawValue, systemImage: theme.icon)
                                .tag(theme)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }

                SettingsRow(
                    title: "Global Shortcut",
                    description: allowsGlobalShortcutRegistration
                        ? GlobalShortcutSettingsCopy.enabledDescription
                        : GlobalShortcutSettingsCopy.developmentDisabledDescription
                ) {
                    GlobalShortcutRecorder(shortcut: $draftGlobalShortcut)
                        .disabled(!allowsGlobalShortcutRegistration)
                }

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

                SettingsRow(
                    title: "Sync Interval",
                    description: "How often to sync while the panel is open. \"Never\" syncs once when opened."
                ) {
                    Picker("", selection: $draftSyncInterval) {
                        ForEach(SyncInterval.allCases) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
            }

            Section(QuotaSettingsCopy.title) {
                QuotaSettingsGroup(
                    claudeEnabled: $draftClaudeQuotaEnabled,
                    codexEnabled: $draftCodexQuotaEnabled,
                    claudeExpirationDate: $draftClaudeExpirationDate,
                    codexExpirationDate: $draftCodexExpirationDate,
                    refreshInterval: $draftQuotaRefreshInterval
                )
            }

            Section {
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
                            .frame(minWidth: 170)
                    }
                    .disabled(store.isRebuildingUsageData)
                }
            }
        }
        .formStyle(.grouped)
        .contentMargins(
            .top,
            SettingsWindowLayout.groupedFormTopPadding,
            for: .scrollContent
        )
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
                .buttonStyle(UtilityWindowPressButtonStyle())
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
    static let expirationNotSet = "Not set"
    static let expirationPickerTitle = "Subscription Expiration"
    static let today = "Today"
    static let clearExpiration = "Clear"
    static let refreshIntervalTitle = "Refresh Interval"
    static let refreshIntervalDescription = "Refresh while the panel is open. \"Never\" refreshes once when opened."
}

enum ExpirationDateControlStyle {
    static let width: CGFloat = 140
    static let height: CGFloat = 28
    static let cornerRadius: CGFloat = 7
    static let borderWidth: CGFloat = 0.5
}

private struct QuotaSettingsGroup: View {
    @Binding var claudeEnabled: Bool
    @Binding var codexEnabled: Bool
    @Binding var claudeExpirationDate: Date?
    @Binding var codexExpirationDate: Date?
    @Binding var refreshInterval: QuotaRefreshInterval

    var body: some View {
        VStack(spacing: 0) {
            quotaRow(
                title: QuotaSettingsCopy.claudeTitle,
                description: QuotaSettingsCopy.claudeDescription,
                expirationDate: $claudeExpirationDate,
                isOn: $claudeEnabled
            )
            Divider()
            quotaRow(
                title: QuotaSettingsCopy.codexTitle,
                description: QuotaSettingsCopy.codexDescription,
                expirationDate: $codexExpirationDate,
                isOn: $codexEnabled
            )
            Divider()
            HStack(spacing: 16) {
                settingLabel(
                    title: QuotaSettingsCopy.refreshIntervalTitle,
                    description: QuotaSettingsCopy.refreshIntervalDescription
                )
                Spacer(minLength: 16)
                Picker("Refresh Interval", selection: $refreshInterval) {
                    ForEach(QuotaRefreshInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quotaRow(
        title: String,
        description: String,
        expirationDate: Binding<Date?>,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 16) {
            settingLabel(title: title, description: description)
            Spacer(minLength: 16)
            ExpirationDateControl(expirationDate: expirationDate)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
        }
        .padding(.vertical, 8)
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

private struct ExpirationDateControl: View {
    @Binding var expirationDate: Date?
    @State private var isPickerPresented = false
    @State private var displayedMonth = Calendar.current.startOfDay(for: Date())

    var body: some View {
        Button {
            displayedMonth = expirationDate ?? Calendar.current.startOfDay(for: Date())
            isPickerPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(expirationDate.map(SubscriptionExpiration.dateText) ?? QuotaSettingsCopy.expirationNotSet)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(expirationDate == nil ? Color.secondary : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(
                width: ExpirationDateControlStyle.width,
                height: ExpirationDateControlStyle.height
            )
            .background(UtilityWindowDesign.dateControlSurfaceFill)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: ExpirationDateControlStyle.cornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: ExpirationDateControlStyle.cornerRadius,
                    style: .continuous
                )
                .stroke(
                    Color(nsColor: .separatorColor).opacity(0.65),
                    lineWidth: ExpirationDateControlStyle.borderWidth
                )
            }
        }
        .buttonStyle(UtilityWindowPressButtonStyle())
        .overlay(alignment: .trailing) {
            Color.clear
                .frame(width: 1, height: 1)
                .padding(.trailing, 53)
                .offset(y: 10)
                .allowsHitTesting(false)
                .popover(isPresented: $isPickerPresented, arrowEdge: .top) {
                    expirationPopover
                        .frame(width: 252)
                        .padding(10)
                }
        }
        .accessibilityLabel(QuotaSettingsCopy.expirationPickerTitle)
        .accessibilityValue(
            expirationDate.map(SubscriptionExpiration.dateText) ?? QuotaSettingsCopy.expirationNotSet
        )
    }

    private var expirationPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            calendarPicker

            Divider()
            HStack {
                Button(QuotaSettingsCopy.today) {
                    expirationDate = Calendar.current.startOfDay(for: Date())
                    isPickerPresented = false
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .buttonStyle(UtilityWindowPressButtonStyle())

                Spacer()

                if expirationDate != nil {
                    Button(QuotaSettingsCopy.clearExpiration) {
                        expirationDate = nil
                        isPickerPresented = false
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .buttonStyle(UtilityWindowPressButtonStyle())
                }
            }
        }
    }

    private var calendarPicker: some View {
        MonthCalendarView(
            displayedMonth: $displayedMonth,
            weekdayForeground: .secondary,
            appearance: expirationDayAppearance,
            onSelect: selectExpirationDate
        )
    }

    private func selectExpirationDate(_ date: Date) {
        expirationDate = Calendar.current.startOfDay(for: date)
        isPickerPresented = false
    }

    private func expirationDayAppearance(for date: Date) -> MonthCalendarDayAppearance {
        if expirationDate.map({ Calendar.current.isDate(date, inSameDayAs: $0) }) == true {
            return .selected
        }
        if Calendar.current.isDateInToday(date) {
            return .today
        }
        return .standard
    }
}

struct UsageDataRebuildSheetView: View {
    @EnvironmentObject var store: AppStore
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .utilityWindowGroupedSurface()
            actions
        }
        .padding(22)
        .frame(width: 430)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: headerIconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(headerColor)
                .frame(width: 34, height: 34)
                .background(headerColor.opacity(0.12))
                .clipShape(Circle())

            Text(headerTitle)
                .font(.system(size: 15, weight: .semibold))
        }
    }

    private var headerTitle: String {
        if store.isRebuildingUsageData {
            return store.usageDataRebuildProgress?.phase?.displayName
                ?? UsageDataRebuildCopy.runningMessage
        }
        if store.usageDataRebuildSummary != nil { return UsageDataRebuildCopy.successTitle }
        if store.usageDataRebuildWasCancelled { return UsageDataRebuildCopy.canceledTitle }
        if store.usageDataRebuildErrorMessage != nil { return UsageDataRebuildCopy.failureTitle }
        return UsageDataRebuildCopy.confirmationTitle
    }

    private var headerIconName: String {
        if store.isRebuildingUsageData { return "arrow.triangle.2.circlepath" }
        if store.usageDataRebuildSummary != nil { return "checkmark.circle.fill" }
        if store.usageDataRebuildWasCancelled { return "xmark.circle.fill" }
        if store.usageDataRebuildErrorMessage != nil { return "exclamationmark.triangle.fill" }
        return "externaldrive.badge.timemachine"
    }

    private var headerColor: Color {
        if store.usageDataRebuildSummary != nil { return StatusPalette.success }
        if store.usageDataRebuildWasCancelled { return .secondary }
        if store.usageDataRebuildErrorMessage != nil { return StatusPalette.warning }
        return .accentColor
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
        } else if store.usageDataRebuildWasCancelled {
            Text("Your existing usage data was not changed.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
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
                Button("Cancel Rebuild", role: .cancel) {
                    store.cancelUsageDataRebuild()
                }
                .disabled(store.usageDataRebuildProgress?.phase?.isCancellable == false)
            } else if store.usageDataRebuildSummary != nil {
                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            } else if store.usageDataRebuildWasCancelled || store.usageDataRebuildErrorMessage != nil {
                Button("Close", role: .cancel) {
                    isPresented = false
                }
                Button("Retry") {
                    store.rebuildLocalUsageData()
                }
                .buttonStyle(.borderedProminent)
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
            if let progress, progress.totalBytes > 0 || progress.totalFiles > 0 {
                ProgressView(value: progress.fractionCompleted)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            HStack {
                Text(fileProgressText)
                Spacer()
                Text(byteProgressText)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            HStack {
                Text(progress?.currentSource ?? " ")
                Spacer()
                Text(recordProgressText)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private var fileProgressText: String {
        guard let progress else { return "Preparing files..." }
        guard progress.totalFiles > 0 else { return "Preparing files..." }
        return "\(progress.completedFiles) / \(progress.totalFiles) files"
    }

    private var byteProgressText: String {
        guard let progress, progress.totalBytes > 0 else { return " " }
        return "\(formatBytes(progress.processedBytes)) / \(formatBytes(progress.totalBytes))"
    }

    private var recordProgressText: String {
        guard let progress else { return "0 requests rebuilt" }
        let label = progress.recordsSynced == 1 ? "request" : "requests"
        return "\(progress.recordsSynced) \(label) rebuilt"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - App Source Tab

/// Tab selector for Claude Code / Codex within Extensions, Config, and Prompt categories.
enum AppSourceTab: String, CaseIterable, Identifiable {
    case claude = "Claude Code"
    case codex = "Codex"

    var id: String { rawValue }
}

enum AppSourceTabBarLayout {
    static let horizontalPadding: CGFloat = 20
    static let height: CGFloat = 28
    static let segmentSpacing: CGFloat = 2
    static let containerInset: CGFloat = 2
    static let cornerRadius: CGFloat = 7
}

struct AppSourceTabBar: View {
    @Binding var selection: AppSourceTab

    var body: some View {
        HStack(spacing: AppSourceTabBarLayout.segmentSpacing) {
            ForEach(AppSourceTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(
                            selection == tab
                                ? UtilityWindowDesign.selectedControlText
                                : Color.primary
                        )
                        .frame(maxWidth: .infinity)
                        .frame(
                            height: AppSourceTabBarLayout.height
                                - (AppSourceTabBarLayout.containerInset * 2)
                        )
                        .background(selection == tab ? Color.accentColor : Color.clear)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: AppSourceTabBarLayout.cornerRadius - 2,
                                style: .continuous
                            )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(UtilityWindowPressButtonStyle())
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(AppSourceTabBarLayout.containerInset)
        .frame(maxWidth: .infinity)
        .frame(height: AppSourceTabBarLayout.height)
        .background(UtilityWindowDesign.groupedSurfaceFill)
        .clipShape(
            RoundedRectangle(
                cornerRadius: AppSourceTabBarLayout.cornerRadius,
                style: .continuous
            )
        )
        .padding(.horizontal, AppSourceTabBarLayout.horizontalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Source")
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
            SourcePathHeader(path: subtitle, finderKind: .file) {
                Text(SourcePathPresentation.fileName(for: subtitle))
                    .font(.system(size: 13, weight: .semibold))
            }

            if fileExists {
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: UtilityWindowDesign.compactCornerRadius, style: .continuous)
                            .fill(UtilityWindowDesign.groupedSurfaceFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: UtilityWindowDesign.compactCornerRadius, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
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
                .utilityWindowGroupedSurface(cornerRadius: UtilityWindowDesign.compactCornerRadius)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Reusable Row

struct SettingsRow<Control: View>: View {
    let title: String
    let description: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        LabeledContent {
            control()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}
