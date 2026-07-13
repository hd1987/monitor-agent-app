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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var settingsPanel: NSWindow?
    private var aboutPanel: NSWindow?
    private var statusMenu: NSMenu!
    private var rightClickHandled = false
    private let store = AppStore()
    private let themeManager = ThemeManager.shared
    private var themeCancellable: AnyCancellable?

    private var forceQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = Self.makeMenuBarIcon()
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
        menu.addItem(configItem)
        menu.addItem(promptItem)
        menu.addItem(.separator())
        menu.addItem(updateItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusMenu = menu

        let hostingView = NSHostingView(
            rootView: PopoverView()
                .environmentObject(store)
                .environmentObject(themeManager)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        panel = FloatingPanel()
        panel.onHide = { [weak self] in
            self?.store.panelDidClose()
        }
        panel.contentView = hostingView

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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !forceQuit && SyncSettings.shared.keepInBackground {
            hidePanel()
            settingsPanel?.close()
            aboutPanel?.close()
            return .terminateCancel
        }
        return .terminateNow
    }

    private func applyTheme() {
        panel.backgroundLayer?.backgroundColor = themeManager.panelBackground.cgColor
        panel.backgroundLayer?.borderColor = themeManager.panelBorder.cgColor
        panel.appearance = themeManager.nsAppearance

        // Update already-open windows
        settingsPanel?.appearance = themeManager.nsAppearance
        aboutPanel?.appearance = themeManager.nsAppearance
        UpdateChecker.shared.applyTheme()
    }

    @objc private func togglePanel(_ sender: AnyObject?) {
        guard !rightClickHandled else { return }

        if panel.isVisible {
            hidePanel()
            return
        }

        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)

        let panelSize = panel.contentView?.fittingSize ?? NSSize(width: 620, height: 400)
        panel.setContentSize(panelSize)

        let x = screenRect.midX - panelSize.width / 2
        let y = screenRect.minY - panelSize.height - 4

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
        store.panelDidOpen()
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    @objc func openSettings(_ sender: AnyObject?) {
        openSettings(category: .general)
    }

    @objc private func openSettingsGeneral(_ sender: AnyObject?) {
        openSettings(category: .general)
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

        let hosting = NSHostingView(
            rootView: SettingsView(initialCategory: category)
                .environmentObject(store)
                .environmentObject(themeManager)
        )

        let w = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SettingsWindowLayout.minimumWidth,
                height: SettingsWindowLayout.minimumHeight
            ),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        w.title = ""
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.hidesOnDeactivate = false
        w.appearance = themeManager.nsAppearance
        w.contentView = hosting
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsPanel = w
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
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.level = .floating
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

    /// Force quit bypassing keepInBackground check (used by update restart)
    func forceTerminate() {
        forceQuit = true
        NSApplication.shared.terminate(nil)
        ForceTermination.scheduleFallbackExit()
    }

    @objc private func quitApp(_ sender: AnyObject?) {
        forceTerminate()
    }

    /// Build menu bar icon from bundled SVG
    private static func makeMenuBarIcon() -> NSImage {
        let svgString = """
        <svg viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg" width="18" height="18">
        <path d="M236.397714 911.36c0 27.940571 22.674286 50.614857 50.614857 50.614857h449.974858a50.614857 50.614857 0 1 0 0-101.229714H287.012571a50.614857 50.614857 0 0 0-50.614857 50.614857z m506.368-666.989714h50.468572a168.740571 168.740571 0 0 1 168.667428 168.740571v224.914286a168.740571 168.740571 0 0 1-168.740571 168.740571H230.765714A168.740571 168.740571 0 0 1 62.171429 638.025143V413.110857A168.740571 168.740571 0 0 1 230.765714 244.297143h50.468572l-20.553143-123.392a50.614857 50.614857 0 0 1 99.913143-16.676572l22.454857 134.948572 0.658286 5.046857h256.585142l0.585143-5.046857 22.528-134.875429a50.614857 50.614857 0 0 1 99.913143 16.749715l-20.553143 123.172571v0.073143z m-460.214857 236.251428v44.982857a50.614857 50.614857 0 0 0 101.229714 0V480.548571a50.614857 50.614857 0 1 0-101.229714 0z m357.668572 0v44.982857a50.614857 50.614857 0 0 0 101.229714 0V480.548571a50.614857 50.614857 0 0 0-101.229714 0z" fill="#000000"/>
        </svg>
        """
        guard let data = svgString.data(using: .utf8),
              let image = NSImage(data: data) else {
            return NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Monitor Agent")!
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}

// MARK: - Floating Panel

final class FloatingPanel: NSPanel {
    /// Exposed for theme updates
    private(set) var backgroundLayer: CALayer?
    var onHide: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSView(frame: .zero)
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.98).cgColor
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 1.0 / (NSScreen.main?.backingScaleFactor ?? 2)
        bg.layer?.borderColor = NSColor.black.withAlphaComponent(0.01).cgColor
        bg.translatesAutoresizingMaskIntoConstraints = false
        backgroundLayer = bg.layer

        let wrapper = NSView(frame: .zero)
        wrapper.wantsLayer = true
        wrapper.layer?.cornerRadius = 12
        wrapper.layer?.masksToBounds = true
        wrapper.translatesAutoresizingMaskIntoConstraints = false

        wrapper.addSubview(bg)
        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            bg.topAnchor.constraint(equalTo: wrapper.topAnchor),
            bg.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
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

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        onHide?()
    }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}

private protocol _AnyNSHostingView: NSView {}
extension NSHostingView: _AnyNSHostingView {}
