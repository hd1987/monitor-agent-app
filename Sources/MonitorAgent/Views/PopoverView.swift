import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var theme: ThemeManager
    @State private var appFilterFrameInWindow: CGRect = .null

    var body: some View {
        VStack(spacing: 0) {
            FilterBar { frame in
                appFilterFrameInWindow = frame
            }
            Divider().opacity(theme.dividerOpacity)
            StatCardsView()
            Divider().opacity(theme.dividerOpacity).padding(.horizontal, 16)
            HeatmapView(appFilterFrameInWindow: appFilterFrameInWindow)
            Divider().opacity(theme.dividerOpacity).padding(.horizontal, 16)
            ModelDistributionView()
        }
        .frame(width: 620)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .preferredColorScheme(theme.colorScheme)
    }
}
