import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var theme: ThemeManager
    let onOpenGeneralSettings: () -> Void
    let onResetPanelPosition: () -> Void
    @State private var appFilterFrameInWindow: CGRect = .null
    @State private var isTokenBreakdownPresented = false

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(
                onOpenGeneralSettings: onOpenGeneralSettings,
                onResetPanelPosition: onResetPanelPosition,
                onAppFilterFrameChange: { frame in
                    appFilterFrameInWindow = frame
                }
            )
            Divider().opacity(theme.dividerOpacity)
            StatCardsView(isTokenBreakdownPresented: $isTokenBreakdownPresented)
            Divider().opacity(theme.dividerOpacity).padding(.horizontal, 16)
            HeatmapView(appFilterFrameInWindow: appFilterFrameInWindow)
                .allowsHitTesting(!isTokenBreakdownPresented)
            Divider().opacity(theme.dividerOpacity).padding(.horizontal, 16)
            ModelDistributionView()
            SubscriptionQuotaView()
        }
        .frame(width: 620)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .preferredColorScheme(theme.colorScheme)
    }
}
