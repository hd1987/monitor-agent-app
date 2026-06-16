import SwiftUI
import AppKit

@main
struct MonitorAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var statusMenu: NSMenu!
    private var rightClickHandled = false
    private let store = AppStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = Self.makeMenuBarIcon()
            button.action = #selector(togglePanel(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp])
        }

        // Right-click context menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(openSettings(_:)), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp(_:)), keyEquivalent: "q"))
        statusMenu = menu

        let hostingView = NSHostingView(
            rootView: PopoverView()
                .environmentObject(store)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        panel = FloatingPanel()
        panel.contentView = hostingView

        // Close panel when clicking outside
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.panel.orderOut(nil)
        }

        // Right-click on status item → show context menu
        NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self,
                  let button = self.statusItem.button,
                  event.window == button.window else { return event }
            self.rightClickHandled = true
            self.panel.orderOut(nil)
            self.statusItem.menu = self.statusMenu
            self.statusItem.button?.performClick(nil)
            DispatchQueue.main.async {
                self.statusItem.menu = nil
                self.rightClickHandled = false
            }
            return nil
        }
    }

    @objc private func togglePanel(_ sender: AnyObject?) {
        // Skip if right-click just handled the menu
        guard !rightClickHandled else { return }

        if panel.isVisible {
            panel.orderOut(nil)
            return
        }

        guard let button = statusItem.button,
              let buttonWindow = button.window else { return }

        // Position below the menu bar icon, centered
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)

        let panelSize = panel.contentView?.fittingSize ?? NSSize(width: 620, height: 400)
        panel.setContentSize(panelSize)

        let x = screenRect.midX - panelSize.width / 2
        let y = screenRect.minY - panelSize.height - 4

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings(_ sender: AnyObject?) {
        // TODO: open settings window
    }

    @objc private func quitApp(_ sender: AnyObject?) {
        NSApplication.shared.terminate(nil)
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
        hasShadow = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // White background with 95% opacity
        let visualEffect = NSView(frame: .zero)
        visualEffect.wantsLayer = true
        visualEffect.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.98).cgColor
        visualEffect.layer?.cornerRadius = 12
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 1.0 / NSScreen.main!.backingScaleFactor
        visualEffect.layer?.borderColor = NSColor.black.withAlphaComponent(0.01).cgColor
        visualEffect.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView(frame: .zero)
        wrapper.wantsLayer = true
        wrapper.layer?.cornerRadius = 12
        wrapper.layer?.masksToBounds = true
        wrapper.translatesAutoresizingMaskIntoConstraints = false

        wrapper.addSubview(visualEffect)
        NSLayoutConstraint.activate([
            visualEffect.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            visualEffect.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            visualEffect.topAnchor.constraint(equalTo: wrapper.topAnchor),
            visualEffect.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])

        self.contentView = wrapper
    }

    override var contentView: NSView? {
        get { super.contentView }
        set {
            if let hosting = newValue as? NSHostingView<AnyView> ?? newValue as? _AnyNSHostingView {
                // Insert hosting view on top of the visual effect background
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

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}

/// Type-erased protocol to detect any NSHostingView
private protocol _AnyNSHostingView: NSView {}
extension NSHostingView: _AnyNSHostingView {}
