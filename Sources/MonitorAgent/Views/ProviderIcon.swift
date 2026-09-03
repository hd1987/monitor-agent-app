import AppKit
import SwiftUI

struct ProviderIcon: View {
    let provider: QuotaProviderID

    var body: some View {
        Image(nsImage: ProviderIconAsset.image(for: provider))
            .resizable()
            .scaledToFit()
            .foregroundStyle(.primary)
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }
}

enum ProviderIconAsset {
    static func data(for provider: QuotaProviderID) -> Data? {
        AppIconAsset.data(for: appIcon(for: provider))
    }

    static func image(for provider: QuotaProviderID) -> NSImage {
        AppIconAsset.image(for: appIcon(for: provider))
    }

    private static func appIcon(for provider: QuotaProviderID) -> AppIcon {
        switch provider {
        case .claude: return .claude
        case .codex: return .codex
        case .cursor: return .cursor
        }
    }
}
