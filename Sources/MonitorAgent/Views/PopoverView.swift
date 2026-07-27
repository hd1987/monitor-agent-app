import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var theme: ThemeManager
    let onOpenGeneralSettings: () -> Void
    let onResetPanelPosition: () -> Void
    @State private var filterBarFrameInWindow: CGRect = .null
    @State private var isTokenBreakdownPresented = false

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(
                onOpenGeneralSettings: onOpenGeneralSettings,
                onResetPanelPosition: onResetPanelPosition,
                onFilterBarFrameChange: { frame in
                    filterBarFrameInWindow = frame
                }
            )
            StatCardsView(isTokenBreakdownPresented: $isTokenBreakdownPresented)
            HeatmapView(filterBarFrameInWindow: filterBarFrameInWindow)
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
