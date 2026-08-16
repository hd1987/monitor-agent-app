import SwiftUI
import AppKit
import Combine
import Darwin

enum ForceTermination {
    static let fallbackDelay: TimeInterval = 0.2

    static func scheduleFallbackExit(
        scheduler: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { block() }
        },
        exit: @escaping (Int32) -> Void = { Darwin.exit($0) }
    ) {
        scheduler(fallbackDelay) { exit(0) }
    }

    static func exitImmediately(exit: (Int32) -> Void = { Darwin.exit($0) }) {
        exit(0)
    }
}

enum PanelDismissalReason {
    case automatic
    case explicit
}

enum PanelPositioning {
    static let statusItemSpacing: CGFloat = 4

    static func anchoredOrigin(
        statusItemFrame: NSRect,
        panelSize: NSSize,
        visibleFrame: NSRect
    ) -> NSPoint {
        let origin = NSPoint(
            x: statusItemFrame.midX - panelSize.width / 2,
            y: statusItemFrame.minY - panelSize.height - statusItemSpacing
        )
        return constrainedOrigin(origin, panelSize: panelSize, visibleFrame: visibleFrame)
    }

    static func constrainedOrigin(
        _ origin: NSPoint,
        panelSize: NSSize,
        visibleFrame: NSRect
    ) -> NSPoint {
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - panelSize.height)
        return NSPoint(
            x: min(max(origin.x, visibleFrame.minX), maximumX),
            y: min(max(origin.y, visibleFrame.minY), maximumY)
        )
    }
}

final class PanelPresentationState: ObservableObject {
    @Published private(set) var isPinned = false
    @Published private(set) var isPanelFocused = false
    private(set) var hasCustomPosition = false

    var isPinHighlighted: Bool {
        isPinned && isPanelFocused
    }

    func togglePin() {
        isPinned.toggle()
    }

    func setPanelFocused(_ isFocused: Bool) {
        isPanelFocused = isFocused
    }

    func allowsDismissal(for reason: PanelDismissalReason) -> Bool {
        if reason == .explicit {
            return true
        }
        return !isPinned
    }

    func recordCustomPosition() {
        hasCustomPosition = true
    }

    func resetCustomPosition() {
        hasCustomPosition = false
    }
}

@main
struct MonitorAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings") {
                        appDelegate.openSettings(nil)
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

private final class RequestsWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

final class RequestsWindow: NSWindow {
    var onRefreshData: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           PanelShortcutEventMatcher.matches(.refreshData, event: event) {
            if !event.isARepeat {
                onRefreshData?()
            }
            return
        }
        super.sendEvent(event)
    }
}

enum RequestsWindowLayout {
    static let initialSize = NSSize(width: 860, height: 750)
    static let minimumSize = NSSize(width: 860, height: 600)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var settingsPanel: NSWindow?
    private var aboutPanel: NSWindow?
    private var requestsPanel: NSWindow?
    private var requestsViewModel: RequestsViewModel?
    private var requestsWindowDelegate: RequestsWindowDelegate?
    private var statusMenu: NSMenu!
    private var rightClickHandled = false
    private let store = AppStore(
        quotaCache: QuotaSnapshotCache.shared,
        cursorSpendRefresher: CursorSpendRefreshCoordinator(),
        cursorAccountResolver: CursorAccountSession.shared,
        activityPresentationSettings: ActivityPresentationSettings.shared
    )
    private let panelPresentationState = PanelPresentationState()
    private let themeManager = ThemeManager.shared
    private let globalShortcutController = GlobalShortcutController.shared
    private var themeCancellable: AnyCancellable?
    private var settingsDividerMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DatabaseManager.cleanUpTemporaryRebuildDatabase()
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = AppIconAsset.menuBarImage()
            button.action = #selector(togglePanel(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp])
        }

        // Right-click context menu
        let menu = NSMenu()
        let aboutItem = NSMenuItem(title: "About MonitorAgent", action: #selector(openAbout(_:)), keyEquivalent: "")
        aboutItem.target = self

        let generalItem = NSMenuItem(title: "General", action: #selector(openSettingsGeneral(_:)), keyEquivalent: ",")
        generalItem.target = self
        let shortcutsItem = NSMenuItem(title: "Shortcuts", action: #selector(openSettingsShortcuts(_:)), keyEquivalent: "")
        shortcutsItem.target = self
        let extensionsItem = NSMenuItem(title: "MCP & Skill", action: #selector(openSettingsExtensions(_:)), keyEquivalent: "")
        extensionsItem.target = self
        let configItem = NSMenuItem(title: "Config", action: #selector(openSettingsConfig(_:)), keyEquivalent: "")
        configItem.target = self
        let promptItem = NSMenuItem(title: "Prompt", action: #selector(openSettingsPrompt(_:)), keyEquivalent: "")
        promptItem.target = self

        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = self
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        menu.addItem(generalItem)
        menu.addItem(shortcutsItem)
        menu.addItem(extensionsItem)
        menu.addItem(configItem)
        menu.addItem(promptItem)
        menu.addItem(.separator())
        menu.addItem(updateItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusMenu = menu

        let hostingView = NSHostingView(
            rootView: PopoverView { [weak self] in
                self?.openSettings(category: .general)
            } onResetPanelPosition: { [weak self] in
                self?.resetPanelPosition()
            } onOpenRequests: { [weak self] in
                self?.openRequests()
            }
                .environmentObject(store)
                .environmentObject(panelPresentationState)
                .environmentObject(themeManager)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        panel = FloatingPanel()
        panel.allowsAutomaticDismissal = { [weak self] in
            self?.panelPresentationState.allowsDismissal(for: .automatic) ?? true
        }
        panel.onHide = { [weak self] in
            self?.store.panelDidClose()
        }
        panel.onUserMove = { [weak self] in
            self?.panelPresentationState.recordCustomPosition()
        }
        panel.onFocusChange = { [weak self] isFocused in
            self?.panelPresentationState.setPanelFocused(isFocused)
        }
        panel.onCycleAppFilter = { [weak self] reverse in
            guard let self else { return }
            self.store.cycleAppFilter(reverse: reverse)
        }
        panel.onResetPosition = { [weak self] in
            self?.resetPanelPosition()
        }
        panel.onTogglePin = { [weak self] in
            self?.panelPresentationState.togglePin()
        }
        panel.onToggleActivityChart = { [weak self] in
            self?.store.toggleActivityDetail()
        }
        panel.onRefreshData = { [weak self] in
            self?.store.refreshNow()
        }
        panel.contentView = hostingView
        globalShortcutController.configure { [weak self] in
            self?.togglePanel(nil)
        }

        // Apply theme to panel and react to changes
        applyTheme()
        themeCancellable = themeManager.$theme.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyTheme() }
        }

        // Close panel when clicking outside
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }

        // Right-click on status item → show context menu
        NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self,
                  let button = self.statusItem.button,
                  event.window == button.window else { return event }
            self.rightClickHandled = true
            self.hidePanel()
            self.statusItem.menu = self.statusMenu
            self.statusItem.button?.performClick(nil)
            DispatchQueue.main.async {
                self.statusItem.menu = nil
                self.rightClickHandled = false
            }
            return nil
        }

        // Auto-check for updates on launch (silent, 24h throttle)
        UpdateChecker.shared.checkOnLaunch()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !panel.isVisible {
            togglePanel(nil)
        }
        return false
    }

    private func applyTheme() {
        panel.backgroundLayer?.backgroundColor = themeManager.panelBackground.cgColor
        panel.appearance = themeManager.nsAppearance

        // Update already-open windows
        settingsPanel?.appearance = themeManager.nsAppearance
        aboutPanel?.appearance = themeManager.nsAppearance
        requestsPanel?.appearance = themeManager.nsAppearance
        UpdateChecker.shared.applyTheme()
    }

    @objc private func togglePanel(_ sender: AnyObject?) {
        guard !rightClickHandled else { return }

        if panel.isVisible {
            hidePanel(reason: .explicit)
            return
        }

        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)

        let panelSize = panel.contentView?.fittingSize
            ?? NSSize(width: MainPanelDesign.width, height: 400)
        panel.setContentSize(panelSize)

        if panelPresentationState.hasCustomPosition {
            constrainPanelToVisibleFrame(fallbackScreen: buttonWindow.screen)
        } else {
            positionPanelBelowStatusItem(screenRect, fallbackScreen: buttonWindow.screen)
        }
        panel.makeKeyAndOrderFront(nil)
        store.panelDidOpen()
    }

    private func resetPanelPosition() {
        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        panelPresentationState.resetCustomPosition()
        positionPanelBelowStatusItem(screenRect, fallbackScreen: buttonWindow.screen)
    }

    private func positionPanelBelowStatusItem(_ statusItemFrame: NSRect, fallbackScreen: NSScreen?) {
        let visibleFrame = fallbackScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? statusItemFrame
        panel.setFrameOrigin(
            PanelPositioning.anchoredOrigin(
                statusItemFrame: statusItemFrame,
                panelSize: panel.frame.size,
                visibleFrame: visibleFrame
            )
        )
    }

    private func constrainPanelToVisibleFrame(fallbackScreen: NSScreen?) {
        guard let visibleFrame = panel.screen?.visibleFrame
            ?? fallbackScreen?.visibleFrame
            ?? NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(
            PanelPositioning.constrainedOrigin(
                panel.frame.origin,
                panelSize: panel.frame.size,
                visibleFrame: visibleFrame
            )
        )
    }

    private func hidePanel(reason: PanelDismissalReason = .automatic) {
        guard panel.isVisible,
              panelPresentationState.allowsDismissal(for: reason) else { return }
        panel.orderOut(nil)
    }

    @objc func openSettings(_ sender: AnyObject?) {
        openSettings(category: .general)
    }

    @objc private func openSettingsGeneral(_ sender: AnyObject?) {
        openSettings(category: .general)
    }

    @objc private func openSettingsShortcuts(_ sender: AnyObject?) {
        openSettings(category: .shortcuts)
    }

    @objc private func openSettingsExtensions(_ sender: AnyObject?) {
        openSettings(category: .extensions)
    }

    @objc private func openSettingsConfig(_ sender: AnyObject?) {
        openSettings(category: .config)
    }

    @objc private func openSettingsPrompt(_ sender: AnyObject?) {
        openSettings(category: .prompt)
    }

    private func openSettings(category: SettingsCategory) {
        // Always recreate so @State drafts reset to saved values
        settingsPanel?.close()
        settingsPanel = nil

        let hosting = NSHostingController(
            rootView: SettingsView(initialCategory: category)
                .environmentObject(store)
                .environmentObject(themeManager)
        )

        let w = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SettingsWindowLayout.defaultWidth,
                height: SettingsWindowLayout.defaultHeight
            ),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        w.title = ""
        w.titlebarAppearsTransparent = true
        w.titlebarSeparatorStyle = .none
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.level = .normal
        w.hidesOnDeactivate = false
        w.appearance = themeManager.nsAppearance
        w.contentViewController = hosting
        w.minSize = NSSize(
            width: SettingsWindowLayout.minimumWidth,
            height: SettingsWindowLayout.minimumHeight
        )
        SettingsWindowToolbar.prepareForPresentation(w)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsPanel = w
        installSettingsDividerMonitorIfNeeded()
        DispatchQueue.main.async { [weak w] in
            SettingsWindowToolbar.revealAfterPresentation(w)
        }
    }

    private func openRequests() {
        if let existing = requestsPanel, let model = requestsViewModel {
            model.reset(
                provider: store.appFilter,
                timeRange: store.timeRange,
                enabledAgents: store.enabledAgents,
                presentationContext: store.requestPresentationContext
            )
            store.requestsWindowDidOpen()
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model = RequestsViewModel(
            provider: store.appFilter,
            timeRange: store.timeRange,
            enabledAgents: store.enabledAgents,
            presentationContext: store.requestPresentationContext
        )
        let hosting = NSHostingController(
            rootView: RequestsView(model: model)
                .environmentObject(store)
                .environmentObject(themeManager)
        )
        let window = RequestsWindow(
            contentRect: NSRect(origin: .zero, size: RequestsWindowLayout.initialSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.hidesOnDeactivate = false
        window.appearance = themeManager.nsAppearance
        window.contentViewController = hosting
        window.minSize = RequestsWindowLayout.minimumSize
        window.setContentSize(RequestsWindowLayout.initialSize)
        window.onRefreshData = { [weak self] in
            self?.store.refreshNow()
        }
        let windowDelegate = RequestsWindowDelegate { [weak self] in
            self?.store.requestsWindowDidClose()
        }
        window.delegate = windowDelegate
        window.center()
        store.requestsWindowDidOpen()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        requestsViewModel = model
        requestsPanel = window
        requestsWindowDelegate = windowDelegate
    }

    /// Swallow mouse events landing on the settings sidebar divider so it can
    /// never be dragged to resize or collapse. Event-level interception is
    /// independent of SwiftUI's split-view layout, which re-asserts itself.
    private func installSettingsDividerMonitorIfNeeded() {
        guard settingsDividerMonitor == nil else { return }
        // Grab margin on each side of the divider's actual x position.
        let hitMargin: CGFloat = 8
        settingsDividerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved, .cursorUpdate]
        ) { [weak self] event in
            guard
                let self,
                let panel = self.settingsPanel,
                event.window === panel,
                let dividerX = self.settingsDividerX(in: panel)
            else { return event }
            guard abs(event.locationInWindow.x - dividerX) <= hitMargin else { return event }
            // Over the divider: keep the normal cursor and discard the event so
            // the split view neither shows the resize cursor nor starts a drag.
            NSCursor.arrow.set()
            return nil
        }
    }

    /// The sidebar/detail divider x in window coordinates, read from the live
    /// split view so it tracks SwiftUI's actual rendered sidebar width.
    private func settingsDividerX(in panel: NSWindow) -> CGFloat? {
        guard
            let content = panel.contentView,
            let split = Self.firstSplitView(in: content),
            let sidebar = split.arrangedSubviews.first
        else { return nil }
        let edge = NSPoint(x: sidebar.frame.maxX, y: sidebar.frame.minY)
        return split.convert(edge, to: nil).x
    }

    private static func firstSplitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for subview in view.subviews {
            if let found = firstSplitView(in: subview) { return found }
        }
        return nil
    }

    @objc private func openAbout(_ sender: AnyObject?) {
        if let existing = aboutPanel, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(rootView: AboutView())
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let w = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        w.title = "About MonitorAgent"
        w.titlebarAppearsTransparent = true
        w.titlebarSeparatorStyle = .none
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.level = .normal
        w.hidesOnDeactivate = false

        w.appearance = themeManager.nsAppearance
        w.contentView = hosting
        w.setContentSize(hosting.fittingSize)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        aboutPanel = w
    }

    @objc private func checkForUpdates(_ sender: AnyObject?) {
        UpdateChecker.shared.checkForUpdates(silent: false)
    }

    /// Terminate the app and guarantee exit if AppKit does not complete termination.
    func forceTerminate() {
        NSApplication.shared.terminate(nil)
        ForceTermination.scheduleFallbackExit()
    }

    @objc private func quitApp(_ sender: AnyObject?) {
        forceTerminate()
    }

}

enum SettingsWindowToolbar {
    static let sidebarToggleIdentifier = NSToolbarItem.Identifier(
        "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
    )

    static func prepareForPresentation(_ window: NSWindow) {
        window.alphaValue = 0
        window.contentView?.layoutSubtreeIfNeeded()
    }

    static func revealAfterPresentation(_ window: NSWindow?) {
        guard let window else { return }
        removeSidebarToggle(from: window)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        window.alphaValue = 1
    }

    private static func removeSidebarToggle(from window: NSWindow) {
        guard
            let toolbar = window.toolbar,
            let index = toolbar.items.firstIndex(where: {
                $0.itemIdentifier == sidebarToggleIdentifier
            })
        else { return }

        toolbar.removeItem(at: index)
    }
}

// MARK: - Floating Panel

final class FloatingPanel: NSPanel, NSWindowDelegate {
    /// Exposed for theme updates
    private(set) var backgroundLayer: CALayer?
    var onHide: (() -> Void)?
    var allowsAutomaticDismissal: (() -> Bool)?
    var onUserMove: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onCycleAppFilter: ((Bool) -> Void)?
    var onResetPosition: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onToggleActivityChart: (() -> Void)?
    var onRefreshData: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: MainPanelDesign.width, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        delegate = self
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: .zero)
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.clear.cgColor
        bg.layer?.cornerRadius = MainPanelDesign.cornerRadius
        bg.layer?.cornerCurve = .continuous
        bg.layer?.masksToBounds = true
        bg.translatesAutoresizingMaskIntoConstraints = false

        let tint = NSView(frame: .zero)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.88).cgColor
        tint.layer?.cornerRadius = MainPanelDesign.cornerRadius
        tint.layer?.cornerCurve = .continuous
        tint.layer?.masksToBounds = true
        tint.translatesAutoresizingMaskIntoConstraints = false
        backgroundLayer = tint.layer

        let wrapper = NSView(frame: .zero)
        wrapper.wantsLayer = true
        wrapper.layer?.cornerRadius = MainPanelDesign.cornerRadius
        wrapper.layer?.cornerCurve = .continuous
        wrapper.layer?.masksToBounds = true
        wrapper.translatesAutoresizingMaskIntoConstraints = false

        wrapper.addSubview(bg)
        wrapper.addSubview(tint)
        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            bg.topAnchor.constraint(equalTo: wrapper.topAnchor),
            bg.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            tint.topAnchor.constraint(equalTo: wrapper.topAnchor),
            tint.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])

        self.contentView = wrapper
    }

    override var contentView: NSView? {
        get { super.contentView }
        set {
            if let hosting = newValue as? NSHostingView<AnyView> ?? newValue as? _AnyNSHostingView {
                if let wrapper = super.contentView, let _ = wrapper.subviews.first {
                    hosting.translatesAutoresizingMaskIntoConstraints = false
                    wrapper.addSubview(hosting)
                    NSLayoutConstraint.activate([
                        hosting.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                        hosting.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
                        hosting.topAnchor.constraint(equalTo: wrapper.topAnchor),
                        hosting.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
                    ])
                    return
                }
            }
            super.contentView = newValue
        }
    }

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handlePanelShortcut(event) {
            return
        }
        super.sendEvent(event)
    }

    private func handlePanelShortcut(_ event: NSEvent) -> Bool {
        if PanelShortcutEventMatcher.matches(.togglePin, event: event) {
            onTogglePin?()
            return true
        }
        if PanelShortcutEventMatcher.matches(.toggleActivityChart, event: event) {
            if !event.isARepeat {
                onToggleActivityChart?()
            }
            return true
        }
        if PanelShortcutEventMatcher.matches(.refreshData, event: event) {
            if !event.isARepeat {
                onRefreshData?()
            }
            return true
        }
        if PanelShortcutEventMatcher.matches(.hidePanel, event: event) {
            orderOut(nil)
            return true
        }
        if PanelShortcutEventMatcher.matches(.resetPosition, event: event) {
            onResetPosition?()
            return true
        }
        if PanelShortcutEventMatcher.matches(.cycleFilter, event: event) {
            onCycleAppFilter?(false)
            return true
        }
        // Shift reverses the cycle when the base binding has no Shift of its own.
        if PanelShortcutEventMatcher.matchesReverseFilterCycle(event: event) {
            onCycleAppFilter?(true)
            return true
        }
        return false
    }

    func windowWillMove(_ notification: Notification) {
        onUserMove?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onFocusChange?(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        onFocusChange?(false)
    }

    func constrainToVisibleFrame(at screenPoint: NSPoint) {
        guard let targetScreen = NSScreen.screens.first(where: { $0.visibleFrame.contains(screenPoint) })
            ?? screen else { return }
        let origin = PanelPositioning.constrainedOrigin(
            frame.origin,
            panelSize: frame.size,
            visibleFrame: targetScreen.visibleFrame
        )
        setFrameOrigin(origin)
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        onFocusChange?(false)
        onHide?()
    }

    override func resignKey() {
        super.resignKey()
        guard allowsAutomaticDismissal?() != false else { return }
        orderOut(nil)
    }
}

private protocol _AnyNSHostingView: NSView {}
extension NSHostingView: _AnyNSHostingView {}
