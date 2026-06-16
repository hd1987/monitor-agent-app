import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            FilterBar()
            Divider().opacity(0.2)
            StatCardsView()
            Divider().opacity(0.2).padding(.horizontal, 16)
            HeatmapView()
            Divider().opacity(0.2).padding(.horizontal, 16)
            ModelDistributionView()
        }
        .frame(width: 620)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .preferredColorScheme(.light)
    }
}
