import AppKit
import Charts
import SwiftUI

struct HeatmapView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var theme: ThemeManager
    @State private var hoveredCell: String?
    @State private var hoveredCount: Int = 0
    @State private var hoverAnchor: CGPoint = .zero
    @State private var activityFrameInWindow: CGRect = .null

    private let rows = 7
    private let cellSpacing: CGFloat = 3
    /// Horizontal padding on each side
    private let hPadding: CGFloat = 16
    /// Panel width minus padding → available width for grid
    private var availableWidth: CGFloat { 620 - hPadding * 2 }
    private var hasSelectedActivityTokenUsage: Bool {
        store.hourlyTokenUsage.contains(where: \.hasTokenUsage)
    }

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
                                        if store.selectedActivityDate == entry.date && hasSelectedActivityTokenUsage {
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
                                        if !entry.isPlaceholder && entry.count > 0 {
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

            if let selectedDate = store.selectedActivityDate, hasSelectedActivityTokenUsage {
                ActivityTokenChart(date: selectedDate, usage: store.hourlyTokenUsage)
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
                    isActive: store.selectedActivityDate != nil && hasSelectedActivityTokenUsage,
                    excludedFrames: [activityFrameInWindow],
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
        .onChange(of: store.selectedYear) { _, _ in
            store.clearSelectedActivityDate()
        }
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
        return theme.cellActive.opacity(intensity)
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

// MARK: - Activity Token Chart

private struct ActivityTokenChart: View {
    @EnvironmentObject var theme: ThemeManager
    let date: String
    let usage: [HourlyTokenUsage]

    private var points: [TokenSeriesPoint] {
        usage.flatMap { item in
            [
                TokenSeriesPoint(metric: "Input Tokens", hour: item.hour, value: Double(item.inputTokens)),
                TokenSeriesPoint(metric: "Output Tokens", hour: item.hour, value: Double(item.outputTokens)),
                TokenSeriesPoint(metric: "Cache Read", hour: item.hour, value: Double(item.cacheReadTokens)),
            ]
        }
    }

    private var maxValue: Double {
        max(points.map(\.value).max() ?? 0, 1)
    }

    private var totalTokens: Int64 {
        usage.reduce(Int64(0)) { total, item in
            total + item.inputTokens + item.outputTokens + item.cacheReadTokens
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(chartTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text(formatTokens(totalTokens))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Chart(points) { point in
                LineMark(
                    x: .value("Hour", point.hour),
                    y: .value("Tokens", point.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(by: .value("Metric", point.metric))
            }
            .chartForegroundStyleScale([
                "Input Tokens": Color.blue,
                "Output Tokens": Color.green,
                "Cache Read": Color.orange,
            ])
            .chartXScale(domain: 0...23)
            .chartYScale(domain: 0...maxValue)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let hour = value.as(Int.self) {
                            Text("\(hour)")
                        }
                    }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 128)
        }
        .padding(10)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.cardBorder, lineWidth: 0.5)
        )
        .accessibilityLabel("Hourly token usage for \(date)")
    }

    private var chartTitle: String {
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.dateFormat = "yyyy-MM-dd"

        let output = DateFormatter()
        output.setLocalizedDateFormatFromTemplate("MMM d, yyyy")

        guard let parsedDate = input.date(from: date) else { return date }
        return output.string(from: parsedDate)
    }
}

private struct TokenSeriesPoint: Identifiable {
    let metric: String
    let hour: Int
    let value: Double
    var id: String { "\(metric)-\(hour)" }
}

// MARK: - Outside Click Handling

private struct WindowFrameReader: NSViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> NSView {
        FrameReportingView(onChange: onChange)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? FrameReportingView else { return }
        view.onChange = onChange
        view.reportFrame()
    }
}

private final class FrameReportingView: NSView {
    var onChange: (CGRect) -> Void

    init(onChange: @escaping (CGRect) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportFrame()
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    func reportFrame() {
        guard let superview else { return }
        let frame = convert(bounds, to: nil)
        let superviewFrame = superview.convert(superview.bounds, to: nil)
        let resolvedFrame = frame.isEmpty ? superviewFrame : frame
        DispatchQueue.main.async {
            self.onChange(resolvedFrame)
        }
    }
}

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
