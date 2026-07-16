import AppKit
import SwiftUI

struct HeatmapView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var theme: ThemeManager
    let appFilterFrameInWindow: CGRect
    @State private var hoveredCell: String?
    @State private var hoveredCount: Int = 0
    @State private var hoverAnchor: CGPoint = .zero
    @State private var activityFrameInWindow: CGRect = .null
    @State private var tooltipSize: CGSize = .zero

    private let rows = 7
    private let cellSpacing: CGFloat = 3
    /// Horizontal padding on each side
    private let hPadding: CGFloat = 16
    /// Panel width minus padding → available width for grid
    private var availableWidth: CGFloat { 620 - hPadding * 2 }
    private var tooltipWidth: CGFloat {
        tooltipSize.width > 0 ? tooltipSize.width : ActivityTokenChartLayout.defaultTooltipWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header — tap to dismiss activity chart
            HStack {
                Text("Activity")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                // Unified mode picker: Default | 2025 | 2026 …
                let options = heatmapModeOptions
                HStack(spacing: 12) {
                    ForEach(options, id: \.self) { mode in
                        let isActive = store.heatmapMode == mode
                        Text(heatmapModeLabel(mode))
                            .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(isActive ? .secondary : .tertiary)
                            .onTapGesture { store.heatmapMode = mode }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if store.selectedActivityDate != nil {
                    store.clearSelectedActivityDate()
                }
            }

            // Grid — compute cell size to fit all weeks within available width
            let grid = buildGrid()
            let columns = grid.count
            let heatmapThresholds = ActivityTokenChartLayout.heatmapThresholds(
                for: store.heatmap.map(\.count)
            )
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
                                    .fill(cellColor(
                                        count: entry.count,
                                        isPlaceholder: entry.isPlaceholder,
                                        thresholds: heatmapThresholds
                                    ))
                                    .frame(width: cellSize, height: cellSize)
                                    .contentShape(Rectangle())
                                    .background(GeometryReader { geo in
                                        Color.clear.preference(
                                            key: CellFrameKey.self,
                                            value: entry.date == hoveredCell
                                                ? geo.frame(in: .named("heatmapGrid"))
                                                : nil
                                        )
                                    })
                                    .overlay {
                                        if store.selectedActivityDate == entry.date {
                                            RoundedRectangle(cornerRadius: 2)
                                                .stroke(Color.accentColor, lineWidth: 1.5)
                                        }
                                    }
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
                                    .onTapGesture {
                                        if !entry.isPlaceholder {
                                            store.selectActivityDate(entry.date)
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
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: TooltipSizeKey.self, value: geo.size)
                        })
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.10), radius: 5, x: 0, y: 2)
                        .fixedSize()
                        .offset(
                            x: ActivityTokenChartLayout.tooltipXOffset(
                                anchorX: hoverAnchor.x,
                                tooltipWidth: tooltipWidth,
                                availableWidth: availableWidth
                            ),
                            y: hoverAnchor.y - 28
                        )
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
            .onPreferenceChange(TooltipSizeKey.self) { size in
                tooltipSize = size
            }
            .animation(.easeOut(duration: 0.1), value: hoveredCell)

            // Month labels
            let monthLabels = buildMonthLabels(columns: columns)
            ZStack(alignment: .leading) {
                ForEach(monthLabels, id: \.offset) { label in
                    Text(label.name)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(
                            width: ActivityTokenChartLayout.monthLabelWidth,
                            height: ActivityTokenChartLayout.monthLabelHeight,
                            alignment: .leading
                        )
                        .offset(x: ActivityTokenChartLayout.monthLabelXOffset(
                            column: label.offset,
                            cellSize: cellSize,
                            cellSpacing: cellSpacing,
                            availableWidth: availableWidth
                        ))
                }
            }
            .frame(
                width: availableWidth,
                height: ActivityTokenChartLayout.monthLabelHeight,
                alignment: .leading
            )

            if let selectedDate = store.selectedActivityDate {
                ActivityTokenChartView(
                    date: selectedDate,
                    usage: store.hourlyTokenUsage,
                    isLoading: store.isHourlyTokenUsageLoading
                )
                    .environmentObject(theme)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, hPadding)
        .padding(.vertical, 12)
        .background(
            ZStack {
                WindowFrameReader { frame in
                    activityFrameInWindow = frame
                }
                ActivityChartClickMonitor(
                    isActive: store.selectedActivityDate != nil,
                    excludedFrames: [activityFrameInWindow, appFilterFrameInWindow],
                    onOutsideClick: {
                        store.clearSelectedActivityDate()
                    }
                )
            }
        )
        .onChange(of: store.selectedActivityDate) { _, selectedDate in
            if selectedDate == nil {
                activityFrameInWindow = .null
            }
        }
        .onChange(of: store.heatmapMode) { _, _ in
            store.clearSelectedActivityDate()
        }
    }

    // MARK: - Heatmap Mode Helpers

    /// Build the list of picker options: [.trailing, .year(2025), .year(2026), ...]
    private var heatmapModeOptions: [HeatmapMode] {
        var options: [HeatmapMode] = [.trailing]
        for year in store.availableYears {
            options.append(.year(year))
        }
        return options
    }

    private func heatmapModeLabel(_ mode: HeatmapMode) -> String {
        switch mode {
        case .trailing: return "Default"
        case .year(let y): return String(y)
        }
    }

    // MARK: - Tooltip

    /// Format: "6 requests on May 21st"
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

        let noun = count == 1 ? "request" : "requests"
        return "\(count) \(noun) on \(month) \(day)\(suffix)"
    }

    // MARK: - Grid Construction

    private struct CellEntry {
        let date: String
        let count: Int
        let isPlaceholder: Bool
    }

    /// Build a [week][weekday] grid based on current heatmap mode
    private func buildGrid() -> [[CellEntry]] {
        if store.heatmapMode == .trailing {
            return buildTrailingGrid()
        }
        return buildYearGrid()
    }

    /// Build grid for a calendar year (Jan 1 – Dec 31)
    private func buildYearGrid() -> [[CellEntry]] {
        guard case .year(let year) = store.heatmapMode else { return [] }
        let cal = Calendar(identifier: .gregorian)

        guard let startOfYear = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
              let endOfYear = cal.date(from: DateComponents(year: year, month: 12, day: 31)) else {
            return []
        }

        return buildGridRange(from: startOfYear, to: endOfYear)
    }

    /// Build grid for trailing 365 days ending today
    private func buildTrailingGrid() -> [[CellEntry]] {
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -364, to: today)!

        // Align start to the Monday of that week
        let startWeekday = weekdayIndex(start, cal: cal)
        let alignedStart = cal.date(byAdding: .day, value: -startWeekday, to: start)!

        return buildGridRange(from: alignedStart, to: today)
    }

    /// Shared grid builder for any date range
    private func buildGridRange(from startDate: Date, to endDate: Date) -> [[CellEntry]] {
        let cal = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        var lookup: [String: Int] = [:]
        for item in store.heatmap {
            lookup[item.date] = item.count
        }

        var weeks: [[CellEntry]] = []
        var currentWeek = Array(repeating: CellEntry(date: "", count: 0, isPlaceholder: true), count: 7)

        var day = startDate
        let firstDayIndex = weekdayIndex(startDate, cal: cal)
        for i in 0..<firstDayIndex {
            currentWeek[i] = CellEntry(date: "", count: 0, isPlaceholder: true)
        }

        while day <= endDate {
            let idx = weekdayIndex(day, cal: cal)
            let key = formatter.string(from: day)
            let count = lookup[key] ?? 0
            currentWeek[idx] = CellEntry(date: key, count: count, isPlaceholder: false)

            if idx == 6 {
                weeks.append(currentWeek)
                currentWeek = Array(repeating: CellEntry(date: "", count: 0, isPlaceholder: true), count: 7)
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }

        if currentWeek.contains(where: { !$0.isPlaceholder }) {
            weeks.append(currentWeek)
        }

        return weeks
    }

    /// Remap weekday: Mon=0 ... Sun=6
    private func weekdayIndex(_ date: Date, cal: Calendar) -> Int {
        let wd = cal.component(.weekday, from: date) // 1=Sun
        return (wd + 5) % 7
    }

    private func cellColor(count: Int, isPlaceholder: Bool, thresholds: [Int]) -> Color {
        if isPlaceholder { return .clear }
        if count == 0 { return theme.cellEmpty }
        let intensity = ActivityTokenChartLayout.heatmapIntensity(
            for: count,
            thresholds: thresholds
        )
        return theme.cellActive.opacity(intensity)
    }

    // MARK: - Month Labels

    private struct MonthLabel: Identifiable {
        let name: String
        let offset: Int
        var id: Int { offset }
    }

    private func buildMonthLabels(columns: Int) -> [MonthLabel] {
        guard columns > 0 else { return [] }

        let cal = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"

        // Determine the actual start date of the grid
        let gridStartDate: Date
        switch store.heatmapMode {
        case .trailing:
            let today = cal.startOfDay(for: Date())
            let trailingStart = cal.date(byAdding: .day, value: -364, to: today)!
            let startWeekday = weekdayIndex(trailingStart, cal: cal)
            gridStartDate = cal.date(byAdding: .day, value: -startWeekday, to: trailingStart)!
        case .year(let year):
            gridStartDate = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
        }

        var labels: [MonthLabel] = []
        // Track by year-month to handle cross-year correctly
        var prevYearMonth = ""
        var prevMonth = -1
        var currentStart = 0

        for week in 0..<columns {
            let approxDate = cal.date(byAdding: .day, value: week * 7, to: gridStartDate)!
            let month = cal.component(.month, from: approxDate)
            let year = cal.component(.year, from: approxDate)
            let yearMonth = "\(year)-\(month)"

            if yearMonth != prevYearMonth {
                if !prevYearMonth.isEmpty {
                    let labelDate = cal.date(from: DateComponents(
                        year: Int(prevYearMonth.split(separator: "-").first!)!,
                        month: prevMonth
                    ))!
                    labels.append(MonthLabel(
                        name: formatter.string(from: labelDate),
                        offset: currentStart
                    ))
                }
                currentStart = week
                prevMonth = month
                prevYearMonth = yearMonth
            }
        }
        // Last month
        if !prevYearMonth.isEmpty {
            let labelDate = cal.date(from: DateComponents(
                year: Int(prevYearMonth.split(separator: "-").first!)!,
                month: prevMonth
            ))!
            labels.append(MonthLabel(
                name: formatter.string(from: labelDate),
                offset: currentStart
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

private struct TooltipSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

// MARK: - Outside Click Handling

private struct ActivityChartClickMonitor: NSViewRepresentable {
    let isActive: Bool
    let excludedFrames: [CGRect]
    let onOutsideClick: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.update(
            isActive: isActive,
            excludedFrames: excludedFrames,
            onOutsideClick: onOutsideClick,
            owner: view
        )
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            isActive: isActive,
            excludedFrames: excludedFrames,
            onOutsideClick: onOutsideClick,
            owner: nsView
        )
    }

    final class Coordinator {
        private var monitor: Any?
        private weak var owner: NSView?
        private var isActive = false
        private var excludedFrames: [CGRect] = []
        private var onOutsideClick: () -> Void = {}

        deinit {
            removeMonitor()
        }

        func update(
            isActive: Bool,
            excludedFrames: [CGRect],
            onOutsideClick: @escaping () -> Void,
            owner: NSView
        ) {
            self.isActive = isActive
            self.excludedFrames = excludedFrames.filter { !$0.isNull && !$0.isEmpty }
            self.onOutsideClick = onOutsideClick
            self.owner = owner

            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                    self?.handle(event) ?? event
                }
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent {
            guard isActive, event.window === owner?.window else { return event }
            let point = event.locationInWindow
            if excludedFrames.contains(where: { $0.contains(point) }) {
                return event
            }

            DispatchQueue.main.async {
                self.onOutsideClick()
            }
            return event
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}
