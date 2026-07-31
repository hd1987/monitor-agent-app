import AppKit
import SwiftUI

enum AppIcon: String, CaseIterable {
    case all
    case claude
    case codex
    case cursor
}

enum AppIconAsset {
    static func data(for icon: AppIcon) -> Data? {
        guard let url = Bundle.module.url(
            forResource: icon.rawValue,
            withExtension: "svg",
            subdirectory: "Icons"
        ) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    static func image(for icon: AppIcon) -> NSImage {
        guard let data = data(for: icon), let image = NSImage(data: data) else {
            return NSImage()
        }
        image.isTemplate = icon != .cursor
        return image
    }
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
