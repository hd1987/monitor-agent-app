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
    private let store = AppStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = Self.makeMenuBarIcon()
            button.action = #selector(togglePanel(_:))
            button.target = self
        }

        let hostingView = NSHostingView(
            rootView: PopoverView()
                .environmentObject(store)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        panel = FloatingPanel()
        panel.contentView = hostingView

        // Close when clicking outside
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.panel.orderOut(nil)
        }
    }

    @objc private func togglePanel(_ sender: AnyObject?) {
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

    /// Build menu bar icon from bundled SVG
    private static func makeMenuBarIcon() -> NSImage {
        let svgString = """
        <svg viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg" width="18" height="18">
        <path d="M458 476.6L170.8 332.9c-19.6-9.8-38.6-10.2-53.4-1-14.8 9.2-23 26.2-23 48.1v332.2c0 31.4 21.7 67.7 49.3 82.8l289.1 156.6c10.5 5.7 20.8 8.6 30.6 8.6 8.1 0 15.6-2 22.2-5.9 14.7-8.8 22.9-25.7 22.9-47.6V558.2c0-15.4-5.2-32.2-14.5-47.4-9.4-15.1-22.2-27.3-36-34.2z m-7.3 81.6v337.4L171.2 744.2c-8.9-4.8-19.1-21.9-19.1-32V388.3l280 140c8.7 4.3 18.6 20.2 18.6 29.9zM874.5 300.8c19.3-9.5 29.9-23.1 29.8-38.3 0-15.2-10.6-28.8-29.9-38.3l-302-148c-16.3-8-37.8-12.3-60.5-12.3-22.7 0-44.2 4.4-60.4 12.3l-302 147.9c-19.3 9.5-29.8 23.1-29.8 38.3 0 15.2 10.6 28.8 29.9 38.3l302 148c16.3 8 37.8 12.3 60.5 12.3 22.7 0 44.2-4.4 60.4-12.3l302-147.9z m-671.8-38.4L477 128.1c18-8.8 52-8.8 70.1 0l274.2 134.3L547 396.8c-18 8.8-52 8.8-70.1 0L202.7 262.4zM906.7 332.4c-14.8-8.8-33.6-7.9-52.9 2.6L581 483.3c-27.6 15.1-49.3 51.6-49.3 82.9v340.3c0 22 8.1 38.8 22.8 47.4 6.4 3.7 13.6 5.6 21.4 5.6 10 0 20.4-3.1 31.1-9.1l273.8-154.7c13.3-7.6 25.7-20.3 34.8-35.8 9.1-15.5 14.1-32.5 14.1-47.7V380c-0.1-21.9-8.2-38.8-23-47.6z m-34.9 58.7v321c0 10.4-10.3 28.1-19.4 33.2L589.5 893.9V566.2c0-10.1 10.2-27.2 19.1-32.1l263.2-143z" fill="#000000"/>
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

        // Solid frosted glass background
        let visualEffect = NSVisualEffectView(frame: .zero)
        visualEffect.material = .sidebar
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.appearance = NSAppearance(named: .aqua)
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 0.5
        visualEffect.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
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
