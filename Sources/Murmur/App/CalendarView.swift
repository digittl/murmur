import SwiftUI

/// A compact month calendar. Days that hold entries get a dot; tapping a day
/// filters the diary feed to that day (tapping again clears the filter).
struct CalendarView: View {
    @Binding var month: Date
    let populatedDays: Set<Date>
    let selectedDay: Date?
    let onSelectDay: (Date) -> Void

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        VStack(spacing: 8) {
            header
            weekdayLabels
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(daysInGrid.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: 30)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.headline)
            Spacer()
            Button { shift(by: -1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
            Button { month = Date() } label: { Image(systemName: "circle.fill").font(.system(size: 7)) }
                .buttonStyle(.borderless)
                .help("Jump to this month")
            Button { shift(by: 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
        }
    }

    private var weekdayLabels: some View {
        HStack(spacing: 4) {
            ForEach(calendar.veryShortWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let hasEntries = populatedDays.contains(calendar.startOfDay(for: day))
        let isToday = calendar.isDateInToday(day)

        return Button {
            onSelectDay(calendar.startOfDay(for: day))
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.callout)
                    .fontWeight(isToday ? .bold : .regular)
                Circle()
                    .fill(hasEntries ? Color.accentColor : .clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.22) : .clear)
            }
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.5))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!hasEntries)
        .opacity(hasEntries || isToday ? 1 : 0.4)
    }

    // MARK: - Grid math

    private func shift(by months: Int) {
        if let next = calendar.date(byAdding: .month, value: months, to: month) {
            month = next
        }
    }

    /// The 7-column grid for the visible month: leading blanks, then each day.
    private var daysInGrid: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else {
            return []
        }
        let first = interval.start
        let leading = calendar.component(.weekday, from: first) - calendar.firstWeekday
        let pad = (leading + 7) % 7

        let dayCount = calendar.range(of: .day, in: .month, for: month)?.count ?? 0
        var cells: [Date?] = Array(repeating: nil, count: pad)
        for offset in 0..<dayCount {
            cells.append(calendar.date(byAdding: .day, value: offset, to: first))
        }
        return cells
    }
}
