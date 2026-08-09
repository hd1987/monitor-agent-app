import AppKit
import SwiftUI

enum AppIcon: String, CaseIterable {
    case all
    case claude
    case codex
    case cursor
}

enum AppIconAsset {
    static func installedResourceBundleURL(resourceDirectory: URL?) -> URL? {
        resourceDirectory?.appendingPathComponent(
            "MonitorAgent_MonitorAgent.bundle",
            isDirectory: true
        )
    }

    private static func resourceBundle() -> Bundle? {
        switch DatabaseEnvironment.current {
        case .production:
            guard let url = installedResourceBundleURL(resourceDirectory: Bundle.main.resourceURL) else {
                return nil
            }
            return Bundle(path: url.path)
        case .development:
            return Bundle.module
        }
    }

    static func data(named resourceName: String) -> Data? {
        guard let url = resourceBundle()?.url(
            forResource: resourceName,
            withExtension: "svg",
            subdirectory: "Icons"
        ) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    static func data(for icon: AppIcon) -> Data? {
        data(named: icon == .all ? "menubar" : icon.rawValue)
    }

    static func image(for icon: AppIcon) -> NSImage {
        guard let data = data(for: icon), let image = NSImage(data: data) else {
            return NSImage()
        }
        image.isTemplate = icon != .cursor
        return image
    }

    static func menuBarImage() -> NSImage {
        let image = image(for: .all)
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}

enum MainPanelIconAsset {
    static let lineChartImage: NSImage = {
        guard
            let data = AppIconAsset.data(named: "linechart"),
            let image = NSImage(data: data)
        else {
            return NSImage()
        }
        image.isTemplate = true
        return image
    }()

    static let barChartImage: NSImage = {
        guard
            let data = AppIconAsset.data(named: "barchart"),
            let image = NSImage(data: data)
        else {
            return NSImage()
        }
        image.isTemplate = true
        return image
    }()
}

struct AppIconView: View {
    let icon: AppIcon
    var size: CGFloat = 12

    var body: some View {
        Image(nsImage: AppIconAsset.image(for: icon))
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
