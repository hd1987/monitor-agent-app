import SwiftUI

struct HeatmapView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var theme: ThemeManager
    @State private var hoveredCell: String?
    @State private var hoveredCount: Int = 0
    @State private var hoverAnchor: CGPoint = .zero

    private let rows = 7
    private let cellSpacing: CGFloat = 3
    /// Horizontal padding on each side
    private let hPadding: CGFloat = 16
    /// Panel width minus padding → available width for grid
    private var availableWidth: CGFloat { 620 - hPadding * 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Text("Activity")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if store.availableYears.count > 1 {
                    Picker("", selection: $store.selectedYear) {
                        ForEach(store.availableYears, id: \.self) { year in
                            Text(String(year)).tag(year)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 80)
                } else {
                    Text(String(store.selectedYear))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            // Grid — compute cell size to fit all weeks within available width
            let grid = buildGrid()
            let columns = grid.count
            let cellSize = columns > 0
                ? floor((availableWidth - CGFloat(columns - 1) * cellSpacing) / CGFloat(columns))
                : CGFloat(8)

            ZStack(alignment: .topLeading) {
                HStack(alignment: .top, spacing: cellSpacing) {
                    ForEach(0..<columns, id: \.self) { col in
                        VStack(spacing: cellSpacing) {
                            ForEach(0..<rows, id: \.self) { row in
                                let entry = grid[col][row]
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(cellColor(count: entry.count, isPlaceholder: entry.isPlaceholder))
                                    .frame(width: cellSize, height: cellSize)
                                    .background(GeometryReader { geo in
                                        Color.clear.preference(
                                            key: CellFrameKey.self,
                                            value: entry.date == hoveredCell
                                                ? geo.frame(in: .named("heatmapGrid"))
                                                : nil
                                        )
                                    })
                                    .onHover { hovering in
                                        if !entry.isPlaceholder {
                                            if hovering {
                                                hoveredCell = entry.date
                                                hoveredCount = entry.count
                                            } else if hoveredCell == entry.date {
                                                hoveredCell = nil
                                            }
                                        }
                                    }
                            }
                        }
                    }
                }

                // Floating tooltip above hovered cell
                if let cellDate = hoveredCell {
                    Text(tooltipText(date: cellDate, count: hoveredCount))
                        .font(.system(size: 11))
                        .foregroundColor(theme.tooltipForeground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.tooltipBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .fixedSize()
                        .offset(x: max(0, hoverAnchor.x - 60), y: hoverAnchor.y - 28)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .coordinateSpace(name: "heatmapGrid")
            .onPreferenceChange(CellFrameKey.self) { frame in
                if let f = frame {
                    hoverAnchor = CGPoint(x: f.midX, y: f.minY)
                }
            }
            .animation(.easeOut(duration: 0.1), value: hoveredCell)

            // Month labels
            let monthLabels = buildMonthLabels(columns: columns)
            HStack(spacing: 0) {
                ForEach(monthLabels, id: \.offset) { label in
                    Text(label.name)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(width: CGFloat(label.span) * (cellSize + cellSpacing), alignment: .leading)
                }
            }
        }
        .padding(.horizontal, hPadding)
        .padding(.vertical, 12)
    }

    // MARK: - Tooltip

    /// Format: "6 contributions on May 21st"
    private func tooltipText(date: String, count: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let d = formatter.date(from: date) else { return "" }

        let monthFmt = DateFormatter()
        monthFmt.dateFormat = "MMMM"
        let month = monthFmt.string(from: d)

        let day = Calendar.current.component(.day, from: d)
        let suffix: String
        switch day {
        case 1, 21, 31: suffix = "st"
        case 2, 22:     suffix = "nd"
        case 3, 23:     suffix = "rd"
        default:         suffix = "th"
        }

        let noun = count == 1 ? "contribution" : "contributions"
        return "\(count) \(noun) on \(month) \(day)\(suffix)"
    }

    // MARK: - Grid Construction

    private struct CellEntry {
        let date: String
        let count: Int
        let isPlaceholder: Bool
    }

    /// Build a [week][weekday] grid for the selected year
    private func buildGrid() -> [[CellEntry]] {
        let cal = Calendar(identifier: .gregorian)
        let year = store.selectedYear

        guard let startOfYear = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
              let endOfYear = cal.date(from: DateComponents(year: year, month: 12, day: 31)) else {
            return []
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        // Build lookup
        var lookup: [String: Int] = [:]
        for item in store.heatmap {
            lookup[item.date] = item.count
        }

        // weekday: 1=Sun ... 7=Sat → remap to Mon=0 ... Sun=6
        func weekdayIndex(_ date: Date) -> Int {
            let wd = cal.component(.weekday, from: date) // 1=Sun
            return (wd + 5) % 7 // Mon=0, Tue=1 ... Sun=6
        }

        var weeks: [[CellEntry]] = []
        var currentWeek = Array(repeating: CellEntry(date: "", count: 0, isPlaceholder: true), count: 7)

        var day = startOfYear
        // Fill leading placeholders
        let firstDayIndex = weekdayIndex(startOfYear)
        for i in 0..<firstDayIndex {
            currentWeek[i] = CellEntry(date: "", count: 0, isPlaceholder: true)
        }

        while day <= endOfYear {
            let idx = weekdayIndex(day)
            let key = formatter.string(from: day)
            let count = lookup[key] ?? 0
            currentWeek[idx] = CellEntry(date: key, count: count, isPlaceholder: false)

            if idx == 6 {
                weeks.append(currentWeek)
                currentWeek = Array(repeating: CellEntry(date: "", count: 0, isPlaceholder: true), count: 7)
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }

        // Flush last partial week
        if currentWeek.contains(where: { !$0.isPlaceholder }) {
            weeks.append(currentWeek)
        }

        return weeks
    }

    private func cellColor(count: Int, isPlaceholder: Bool) -> Color {
        if isPlaceholder { return .clear }
        if count == 0 { return theme.cellEmpty }

        // Determine intensity based on count percentiles
        let intensity: Double
        switch count {
        case 1...10:    intensity = 0.25
        case 11...50:   intensity = 0.45
        case 51...150:  intensity = 0.65
        case 151...400: intensity = 0.80
        default:        intensity = 1.0
        }
        return Color.accentColor.opacity(intensity)
    }

    // MARK: - Month Labels

    private struct MonthLabel: Identifiable {
        let name: String
        let offset: Int
        let span: Int
        var id: Int { offset }
    }

    private func buildMonthLabels(columns: Int) -> [MonthLabel] {
        guard columns > 0 else { return [] }

        let cal = Calendar(identifier: .gregorian)
        let year = store.selectedYear
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"

        var labels: [MonthLabel] = []
        var prevMonth = -1
        var currentStart = 0

        for week in 0..<columns {
            // Approximate: week 0 starts Jan 1, each week = 7 days
            let approxDate = cal.date(byAdding: .day, value: week * 7, to:
                cal.date(from: DateComponents(year: year, month: 1, day: 1))!)!
            let month = cal.component(.month, from: approxDate)

            if month != prevMonth {
                if prevMonth != -1 {
                    labels.append(MonthLabel(
                        name: formatter.string(from: cal.date(from: DateComponents(year: year, month: prevMonth))!),
                        offset: currentStart,
                        span: week - currentStart
                    ))
                }
                currentStart = week
                prevMonth = month
            }
        }
        // Last month
        if prevMonth != -1 {
            labels.append(MonthLabel(
                name: formatter.string(from: cal.date(from: DateComponents(year: year, month: prevMonth))!),
                offset: currentStart,
                span: columns - currentStart
            ))
        }

        return labels
    }
}

// MARK: - Preference Key

private struct CellFrameKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}
