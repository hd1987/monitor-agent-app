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
        AppIconAsset.data(for: provider == .claude ? .claude : .codex)
    }

    static func image(for provider: QuotaProviderID) -> NSImage {
        AppIconAsset.image(for: provider == .claude ? .claude : .codex)
    }
}
