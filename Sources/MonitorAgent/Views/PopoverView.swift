import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var theme: ThemeManager
    let onOpenGeneralSettings: () -> Void
    let onResetPanelPosition: () -> Void
    let onOpenRequests: () -> Void
    @State private var activeStatCardTip: StatCardTip?
    @State private var isTimeRangePopoverPresented = false

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(
                onOpenGeneralSettings: onOpenGeneralSettings,
                onResetPanelPosition: onResetPanelPosition,
                isTimeRangePopoverPresented: $isTimeRangePopoverPresented
            )
            if store.hasEnabledAgents {
                StatCardsView(
                    activeTip: $activeStatCardTip,
                    onOpenRequests: onOpenRequests
                )
                    .zIndex(StatCardTipLayer.zIndex(for: activeStatCardTip))
                HeatmapView()
                    .allowsHitTesting(activeStatCardTip == nil)
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
        .mainPanelRefreshProgress(
            isRefreshing: store.isRefreshInProgress,
            tint: theme.selectedControlAccent
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: MainPanelDesign.cornerRadius,
                style: .continuous
            )
        )
        .preferredColorScheme(theme.colorScheme)
        .overlay {
            if isTimeRangePopoverPresented {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isTimeRangePopoverPresented = false
                    }
                    .accessibilityHidden(true)
            }
        }
    }
}
