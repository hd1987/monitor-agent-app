import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        VStack(spacing: 0) {
            FilterBar()
            Divider().opacity(theme.dividerOpacity)
            StatCardsView()
            Divider().opacity(theme.dividerOpacity).padding(.horizontal, 16)
            HeatmapView()
            Divider().opacity(theme.dividerOpacity).padding(.horizontal, 16)
            ModelDistributionView()
        }
        .frame(width: 620)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .preferredColorScheme(theme.colorScheme)
    }
}
