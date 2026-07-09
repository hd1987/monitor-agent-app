import SwiftUI

struct FilterBar: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var theme: ThemeManager
    let onAppFilterFrameChange: (CGRect) -> Void

    @State private var isTimeRangePopoverPresented = false
    @State private var calendarSelection = CalendarRangeSelection()
    @State private var displayedMonth = Calendar.current.startOfDay(for: Date())

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
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.cardBorder, lineWidth: 0.5)
            )
            .overlay(
                WindowFrameReader { frame in
                    onAppFilterFrameChange(frame)
                }
                .allowsHitTesting(false)
            )

            Spacer()

            Button {
                syncCalendarSelection(from: store.timeRange)
                isTimeRangePopoverPresented.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(displayTitle(for: store.timeRange))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: 150, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .trailing) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .padding(.trailing, 68)
                    .offset(y: 10)
                    .allowsHitTesting(false)
                    .popover(isPresented: $isTimeRangePopoverPresented, arrowEdge: .top) {
                        timeRangePopover
                            .frame(width: 252)
                            .padding(10)
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var timeRangePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                ForEach(TimeRange.presets) { range in
                    presetButton(for: range)
                }
            }

            Divider()

            calendarPicker
        }
    }

    private func presetButton(for range: TimeRange) -> some View {
        Button {
            withTransaction(Transaction(animation: nil)) {
                store.setTimeRangeFromFilter(range)
                calendarSelection = CalendarRangeSelection()
            }
        } label: {
            Text(range.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(store.timeRange == range ? .white : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    store.timeRange == range
                        ? Color.accentColor
                        : theme.cardBackground
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.cardBorder, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private var calendarPicker: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    moveDisplayedMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)

                Button {
                    displayedMonth = Calendar.current.startOfDay(for: Date())
                } label: {
                    Text(monthTitle(for: displayedMonth))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)

                Button {
                    moveDisplayedMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 0) {
                ForEach(shortWeekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                ForEach(calendarCells(for: displayedMonth)) { cell in
                    if let date = cell.date {
                        Button {
                            selectCalendarDate(date)
                        } label: {
                            Text(dayTitle(for: date))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(dayTextColor(for: date))
                                .frame(maxWidth: .infinity, minHeight: 32)
                                .background(dayBackground(for: date))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                }
            }
        }
    }

    private func syncCalendarSelection(from range: TimeRange) {
        if case .custom(let start, let end) = range {
            calendarSelection = CalendarRangeSelection(start: start, end: end)
            displayedMonth = start
        } else {
            let today = Calendar.current.startOfDay(for: Date())
            calendarSelection = CalendarRangeSelection(start: today, end: today)
            displayedMonth = today
        }
    }

    private func selectCalendarDate(_ date: Date) {
        calendarSelection.select(date)
        guard let start = calendarSelection.start, let end = calendarSelection.end else { return }
        let calendar = Calendar.current
        if calendar.isDate(start, inSameDayAs: end) {
            store.setTimeRangeFromFilter(TimeRange.singleDaySelection(for: start, calendar: calendar))
        } else {
            store.setTimeRangeFromFilter(.custom(start: start, end: end))
        }
    }

    private func moveDisplayedMonth(by value: Int) {
        if let month = Calendar.current.date(byAdding: .month, value: value, to: displayedMonth) {
            displayedMonth = month
        }
    }

    private func displayTitle(for range: TimeRange) -> String {
        range.displayTitle(formatter: Self.displayFormatter)
    }

    private var shortWeekdaySymbols: [String] {
        Array(Calendar.current.shortWeekdaySymbols)
    }

    private func calendarCells(for month: Date) -> [CalendarCell] {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: month)
        guard
            let firstDay = calendar.date(from: components),
            let dayRange = calendar.range(of: .day, in: .month, for: firstDay)
        else {
            return []
        }

        let leadingEmptyCount = calendar.component(.weekday, from: firstDay) - calendar.firstWeekday
        let normalizedLeadingCount = (leadingEmptyCount + 7) % 7
        var cells = (0..<normalizedLeadingCount).map { CalendarCell(index: $0, date: nil) }

        for day in dayRange {
            let date = calendar.date(byAdding: .day, value: day - 1, to: firstDay)
            cells.append(CalendarCell(index: cells.count, date: date))
        }

        return cells
    }

    private func dayTitle(for date: Date) -> String {
        String(Calendar.current.component(.day, from: date))
    }

    private func monthTitle(for date: Date) -> String {
        Self.monthFormatter.string(from: date)
    }

    private func dayTextColor(for date: Date) -> Color {
        isRangeBoundary(date) ? .white : .primary
    }

    private func dayBackground(for date: Date) -> Color {
        if isRangeBoundary(date) {
            return .accentColor
        }
        if isInsideRange(date) {
            return Color.accentColor.opacity(0.18)
        }
        if Calendar.current.isDateInToday(date) {
            return Color.accentColor.opacity(0.08)
        }
        return .clear
    }

    private func isRangeBoundary(_ date: Date) -> Bool {
        let calendar = Calendar.current
        return calendarSelection.start.map { calendar.isDate(date, inSameDayAs: $0) } == true
            || calendarSelection.end.map { calendar.isDate(date, inSameDayAs: $0) } == true
    }

    private func isInsideRange(_ date: Date) -> Bool {
        guard let start = calendarSelection.start, let end = calendarSelection.end else {
            return false
        }
        let day = Calendar.current.startOfDay(for: date)
        return day > start && day < end
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()
}

private struct CalendarCell: Identifiable {
    let index: Int
    let date: Date?

    var id: Int { index }
}
