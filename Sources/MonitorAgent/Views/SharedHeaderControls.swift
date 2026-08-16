import SwiftUI

enum ProviderFilterControlStyle {
    case compactIcons
    case labeledSegments(width: CGFloat)
}

struct ProviderFilterControl: View {
    @EnvironmentObject private var theme: ThemeManager

    let filters: [AppFilter]
    let selection: AppFilter
    let style: ProviderFilterControlStyle
    let cursorFailureHelp: String?
    let onSelect: (AppFilter) -> Void

    var body: some View {
        switch style {
        case .compactIcons:
            compactControl
        case .labeledSegments(let width):
            labeledControl(width: width)
        }
    }

    private var compactControl: some View {
        HStack(spacing: 2) {
            ForEach(filters) { filter in
                Button {
                    onSelect(filter)
                } label: {
                    HStack(spacing: 5) {
                        AppIconView(icon: filter.appIcon)
                            .overlay(alignment: .topTrailing) {
                                if filter == .cursor, cursorFailureHelp != nil {
                                    Circle()
                                        .fill(StatusPalette.error)
                                        .frame(width: 4, height: 4)
                                        .offset(x: 2, y: -2)
                                        .accessibilityHidden(true)
                                }
                            }

                        if selection == filter {
                            Text(filter.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .transition(.opacity)
                        }
                    }
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, selection == filter ? 10 : 7)
                    .frame(height: MainPanelDesign.headerControlItemHeight)
                    .background(selection == filter ? theme.selectedControlSurface : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(MainPanelPressButtonStyle())
                .help(helpText(for: filter))
                .accessibilityLabel(helpText(for: filter))
            }
        }
        .padding(2)
        .frame(height: MainPanelDesign.headerControlHeight)
        .background(theme.controlSurface)
        .clipShape(
            RoundedRectangle(
                cornerRadius: MainPanelDesign.controlCornerRadius,
                style: .continuous
            )
        )
        .layoutPriority(1)
    }

    private func labeledControl(width: CGFloat) -> some View {
        Picker(
            "Provider",
            selection: Binding(
                get: { selection },
                set: onSelect
            )
        ) {
            ForEach(filters) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Provider")
        .controlSize(.regular)
        .frame(width: width, alignment: .leading)
    }

    private func helpText(for filter: AppFilter) -> String {
        guard filter == .cursor else { return filter.rawValue }
        return cursorFailureHelp ?? filter.rawValue
    }
}

enum TimeRangeControlStyle: Equatable {
    case mainPanel
    case utilityWindow

    var controlWidth: CGFloat {
        switch self {
        case .mainPanel: 120
        case .utilityWindow: 0
        }
    }

    var popoverWidth: CGFloat {
        switch self {
        case .mainPanel: 252
        case .utilityWindow: 270
        }
    }

    var popoverPadding: CGFloat {
        switch self {
        case .mainPanel: 10
        case .utilityWindow: 12
        }
    }
}

struct TimeRangeControl: View {
    @EnvironmentObject private var theme: ThemeManager

    let timeRange: TimeRange
    let style: TimeRangeControlStyle
    let onSelect: (TimeRange) -> Void
    @Binding var isPopoverPresented: Bool

    @State private var calendarSelection = CalendarRangeSelection()
    @State private var displayedMonth = Calendar.current.startOfDay(for: Date())

    var body: some View {
        Button {
            syncCalendarSelection(from: timeRange)
            isPopoverPresented.toggle()
        } label: {
            controlLabel
        }
        .buttonStyle(SharedHeaderPressButtonStyle(style: style))
        .overlay(alignment: .trailing) {
            popoverAnchor
        }
    }

    @ViewBuilder
    private var controlLabel: some View {
        switch style {
        case .mainPanel:
            HStack(spacing: 6) {
                Text(timeRange.displayTitle(formatter: Self.displayFormatter))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(
                width: style.controlWidth,
                height: MainPanelDesign.headerControlHeight,
                alignment: .trailing
            )
        case .utilityWindow:
            HStack(spacing: 7) {
                Image(systemName: "calendar")
                Text(timeRange.displayTitle(formatter: Self.displayFormatter))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: MainPanelDesign.headerControlHeight)
            .background(UtilityWindowDesign.dateControlSurfaceFill)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private var popoverAnchor: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .padding(.trailing, style == .mainPanel ? 53 : 0)
            .offset(y: style == .mainPanel ? 10 : 0)
            .allowsHitTesting(false)
            .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
                popoverContent
                    .frame(width: style.popoverWidth)
                    .padding(style.popoverPadding)
            }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: style == .mainPanel ? 8 : 10) {
            HStack(spacing: 5) {
                ForEach(TimeRange.presets) { range in
                    presetButton(for: range)
                }
            }

            Divider()

            MonthCalendarView(
                displayedMonth: $displayedMonth,
                weekdayForeground: theme.panelSecondaryForeground,
                appearance: calendarDayAppearance,
                onSelect: selectCalendarDate
            )
        }
    }

    private func presetButton(for range: TimeRange) -> some View {
        Button {
            withTransaction(Transaction(animation: nil)) {
                onSelect(range)
                calendarSelection = CalendarRangeSelection()
                if style == .utilityWindow {
                    isPopoverPresented = false
                }
            }
        } label: {
            Text(range.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    timeRange == range
                        ? UtilityWindowDesign.selectedControlText
                        : Color.primary
                )
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(timeRange == range ? Color.accentColor : theme.controlSurface)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(SharedHeaderPressButtonStyle(style: style))
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
        withTransaction(Transaction(animation: nil)) {
            if calendar.isDate(start, inSameDayAs: end) {
                onSelect(TimeRange.singleDaySelection(for: start, calendar: calendar))
            } else {
                onSelect(.custom(start: start, end: end))
            }
        }
    }

    private func calendarDayAppearance(for date: Date) -> MonthCalendarDayAppearance {
        if isRangeBoundary(date) {
            return .selected
        }
        if isInsideRange(date) {
            return .inRange
        }
        if Calendar.current.isDateInToday(date) {
            return .today
        }
        return .standard
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
}

private struct SharedHeaderPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let style: TimeRangeControlStyle

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .animation(
                style == .mainPanel
                    ? MainPanelMotion.feedback(reduceMotion: reduceMotion)
                    : UtilityWindowDesign.feedback(reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }

    private var pressedOpacity: Double {
        style == .mainPanel ? 0.78 : 0.76
    }

    private var pressedScale: CGFloat {
        style == .mainPanel ? 0.97 : 0.98
    }
}
