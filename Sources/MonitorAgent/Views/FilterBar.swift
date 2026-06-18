import SwiftUI

struct FilterBar: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        HStack(spacing: 12) {
            // App filter (segmented)
            HStack(spacing: 2) {
                ForEach(AppFilter.allCases) { filter in
                    Button {
                        store.appFilter = filter
                    } label: {
                        Text(filter.rawValue)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                store.appFilter == filter
                                    ? Color.accentColor.opacity(0.25)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Spacer()

            // Time range picker
            Picker("", selection: $store.timeRange) {
                ForEach(TimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 100)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
