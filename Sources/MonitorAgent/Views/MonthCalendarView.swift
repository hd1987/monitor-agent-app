import SwiftUI

enum MonthCalendarDayAppearance: Equatable {
    case standard
    case today
    case inRange
    case selected
}

enum MonthCalendarLayout {
    static let verticalSpacing: CGFloat = 8
    static let gridColumnSpacing: CGFloat = 0
    static let gridRowSpacing: CGFloat = 3
    static let dayHeight: CGFloat = 32
    static let dayCornerRadius: CGFloat = 6
    static let monthButtonSize: CGFloat = 28

    static func weekdaySymbols(calendar: Calendar = .current) -> [String] {
        let symbols = calendar.shortWeekdaySymbols
        guard !symbols.isEmpty else { return [] }
        let startIndex = min(max(calendar.firstWeekday - 1, 0), symbols.count - 1)
        return Array(symbols[startIndex...]) + Array(symbols[..<startIndex])
    }

    static func cells(
        for month: Date,
        calendar: Calendar = .current
    ) -> [MonthCalendarCell] {
        let components = calendar.dateComponents([.year, .month], from: month)
        guard
            let firstDay = calendar.date(from: components),
            let dayRange = calendar.range(of: .day, in: .month, for: firstDay)
        else {
            return []
        }

        let leadingEmptyCount = calendar.component(.weekday, from: firstDay)
            - calendar.firstWeekday
        let normalizedLeadingCount = (leadingEmptyCount + 7) % 7
        var cells = (0..<normalizedLeadingCount).map {
            MonthCalendarCell(index: $0, date: nil)
        }

        for day in dayRange {
            let date = calendar.date(byAdding: .day, value: day - 1, to: firstDay)
            cells.append(MonthCalendarCell(index: cells.count, date: date))
        }

        while cells.count < 42 {
            cells.append(MonthCalendarCell(index: cells.count, date: nil))
        }

        return cells
    }
}

struct MonthCalendarView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var displayedMonth: Date
    let weekdayForeground: Color
    let appearance: (Date) -> MonthCalendarDayAppearance
    let onSelect: (Date) -> Void

    var body: some View {
        VStack(spacing: MonthCalendarLayout.verticalSpacing) {
            monthHeader
            weekdayHeader
            dayGrid
        }
    }

    private var monthHeader: some View {
        HStack {
            monthButton(systemImage: "chevron.left") {
                moveDisplayedMonth(by: -1)
            }

            Text(Self.monthFormatter.string(from: displayedMonth))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)

            monthButton(systemImage: "chevron.right") {
                moveDisplayedMonth(by: 1)
            }
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(MonthCalendarLayout.weekdaySymbols(), id: \.self) { symbol in
                Text(symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(weekdayForeground)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var dayGrid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(
                    .flexible(),
                    spacing: MonthCalendarLayout.gridColumnSpacing
                ),
                count: 7
            ),
            spacing: MonthCalendarLayout.gridRowSpacing
        ) {
            ForEach(MonthCalendarLayout.cells(for: displayedMonth)) { cell in
                if let date = cell.date {
                    dayButton(date)
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: MonthCalendarLayout.dayHeight)
                }
            }
        }
    }

    private func monthButton(
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(
                    width: MonthCalendarLayout.monthButtonSize,
                    height: MonthCalendarLayout.monthButtonSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(pressStyle)
        .accessibilityLabel(
            systemImage == "chevron.left" ? "Previous month" : "Next month"
        )
    }

    private func dayButton(_ date: Date) -> some View {
        let dayAppearance = appearance(date)
        return Button {
            onSelect(date)
        } label: {
            Text(String(Calendar.current.component(.day, from: date)))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(
                    dayAppearance == .selected
                        ? UtilityWindowDesign.selectedControlText
                        : Color.primary
                )
                .frame(maxWidth: .infinity, minHeight: MonthCalendarLayout.dayHeight)
                .background { background(for: dayAppearance) }
                .overlay { todayOutline(for: dayAppearance) }
                .contentShape(Rectangle())
        }
        .buttonStyle(pressStyle)
        .accessibilityLabel(Self.accessibilityFormatter.string(from: date))
        .accessibilityValue(accessibilityValue(for: dayAppearance))
        .accessibilityAddTraits(dayAppearance == .selected ? .isSelected : [])
    }

    private var pressStyle: MonthCalendarPressButtonStyle {
        MonthCalendarPressButtonStyle(reduceMotion: reduceMotion)
    }

    @ViewBuilder
    private func background(for appearance: MonthCalendarDayAppearance) -> some View {
        switch appearance {
        case .selected:
            RoundedRectangle(
                cornerRadius: MonthCalendarLayout.dayCornerRadius,
                style: .continuous
            )
            .fill(Color.accentColor)
        case .inRange:
            Rectangle().fill(Color.accentColor.opacity(0.18))
        case .today, .standard:
            Color.clear
        }
    }

    @ViewBuilder
    private func todayOutline(for appearance: MonthCalendarDayAppearance) -> some View {
        if appearance == .today {
            RoundedRectangle(
                cornerRadius: MonthCalendarLayout.dayCornerRadius,
                style: .continuous
            )
            .stroke(Color.accentColor.opacity(0.65), lineWidth: 1)
            .padding(2)
        }
    }

    private func accessibilityValue(for appearance: MonthCalendarDayAppearance) -> String {
        switch appearance {
        case .selected: return "Selected"
        case .inRange: return "In selected range"
        case .today: return "Today"
        case .standard: return ""
        }
    }

    private func moveDisplayedMonth(by value: Int) {
        if let month = Calendar.current.date(
            byAdding: .month,
            value: value,
            to: displayedMonth
        ) {
            displayedMonth = month
        }
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()

    private static let accessibilityFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()
}

struct MonthCalendarCell: Identifiable {
    let index: Int
    let date: Date?

    var id: Int { index }
}

private struct MonthCalendarPressButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.08)
                    : .spring(response: 0.24, dampingFraction: 1),
                value: configuration.isPressed
            )
    }
}
