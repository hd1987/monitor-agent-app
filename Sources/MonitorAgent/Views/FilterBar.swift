import SwiftUI

struct FilterBar: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var panelPresentationState: PanelPresentationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onOpenGeneralSettings: () -> Void
    let onResetPanelPosition: () -> Void

    @Binding var isTimeRangePopoverPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            PanelDragArea()
                .frame(maxWidth: .infinity)
                .frame(height: 10)

            HStack(spacing: MainPanelDesign.headerToolSpacing) {
                PanelDragArea()
                    .frame(width: 16, height: MainPanelDesign.headerControlHeight)

                headerContent

                PanelDragArea()
                    .frame(width: 16, height: MainPanelDesign.headerControlHeight)
            }

            PanelDragArea()
                .frame(maxWidth: .infinity)
                .frame(height: 10)
        }
    }

    private var headerContent: some View {
        HStack(spacing: 12) {
            ProviderFilterControl(
                filters: store.availableAppFilters,
                selection: store.appFilter,
                style: .compactIcons,
                cursorFailureHelp: store.cursorRefreshFailureHelp,
                onSelect: { store.appFilter = $0 }
            )

            PanelDragArea()
                .frame(
                    maxWidth: .infinity,
                    maxHeight: MainPanelDesign.headerControlHeight
                )

            HStack(spacing: 0) {
                MainPanelHeaderToolButton(
                    helpText: panelPresentationState.isPinned ? "Unpin Panel" : "Keep Panel Open",
                    accessibilityText: panelPresentationState.isPinned ? "Unpin panel" : "Keep panel open",
                    isSelected: panelPresentationState.isPinHighlighted,
                    action: panelPresentationState.togglePin
                ) { foreground in
                    Image(systemName: panelPresentationState.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(foreground)
                        .rotationEffect(
                            panelPresentationState.isPinned || reduceMotion
                                ? .zero
                                : .degrees(45)
                        )
                }

                MainPanelChartButton(
                    chartStyle: store.activityChartStyle,
                    helpText: store.isActivityDetailPresented
                        ? "Collapse Activity detail"
                        : "Show Activity detail",
                    accessibilityText: store.isActivityDetailPresented
                        ? "Collapse Activity detail"
                        : "Show Activity detail",
                    isSelected: store.isActivityDetailPresented,
                    action: store.toggleActivityDetail
                )
                .disabled(!store.hasEnabledAgents)

                UnifiedRefreshButton()

                MainPanelHeaderToolButton(
                    helpText: "Reset Panel Position",
                    accessibilityText: "Reset panel position",
                    action: onResetPanelPosition
                ) { foreground in
                    Image(systemName: "scope")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(foreground)
                }

                MainPanelHeaderToolButton(
                    helpText: "Open General Settings",
                    accessibilityText: "Open General settings",
                    action: onOpenGeneralSettings
                ) { foreground in
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(foreground)
                }
            }
            .padding(2)
            .frame(height: MainPanelDesign.headerControlHeight)

            TimeRangeControl(
                timeRange: store.timeRange,
                style: .mainPanel,
                onSelect: store.setTimeRangeFromFilter,
                isPopoverPresented: $isTimeRangePopoverPresented
            )
        }
    }

}

private struct PanelDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> PanelDragView {
        PanelDragView()
    }

    func updateNSView(_ nsView: PanelDragView, context: Context) {}
}

private final class PanelDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
        (window as? FloatingPanel)?.constrainToVisibleFrame(at: NSEvent.mouseLocation)
    }
}
