import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var theme: ThemeManager
    let onOpenGeneralSettings: () -> Void
    let onResetPanelPosition: () -> Void
    @State private var isTokenBreakdownPresented = false

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(
                onOpenGeneralSettings: onOpenGeneralSettings,
                onResetPanelPosition: onResetPanelPosition
            )
            if store.hasEnabledAgents {
                StatCardsView(isTokenBreakdownPresented: $isTokenBreakdownPresented)
                HeatmapView()
                    .allowsHitTesting(!isTokenBreakdownPresented)
                ModelDistributionView()
                SubscriptionQuotaView()
            } else {
                ContentUnavailableView {
                    Label("No Agents Monitored", systemImage: "waveform.slash")
                } description: {
                    Text("Enable at least one Agent in General Settings.")
                } actions: {
                    Button("Open General Settings") {
                        onOpenGeneralSettings()
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 360)
            }
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
