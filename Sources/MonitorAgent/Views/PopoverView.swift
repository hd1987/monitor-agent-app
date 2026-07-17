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
            StatCardsView(isTokenBreakdownPresented: $isTokenBreakdownPresented)
            HeatmapView(appFilterFrameInWindow: appFilterFrameInWindow)
                .allowsHitTesting(!isTokenBreakdownPresented)
            ModelDistributionView()
            SubscriptionQuotaView()
        }
        .frame(width: MainPanelDesign.width)
        .clipShape(
            RoundedRectangle(
                cornerRadius: MainPanelDesign.cornerRadius,
                style: .continuous
            )
        )
        .preferredColorScheme(theme.colorScheme)
    }
}
