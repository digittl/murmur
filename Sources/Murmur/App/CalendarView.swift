import SwiftUI

/// A compact month calendar. Days that hold entries get a dot; tapping a day
/// filters the diary feed to that day (tapping again clears the filter).
struct CalendarView: View {
    @Binding var month: Date
    let populatedDays: Set<Date>
    let selectedDay: Date?
    let onSelectDay: (Date) -> Void

    @EnvironmentObject private var settings: AppSettings
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
        HStack(spacing: 6) {
            // Subtle click-to-jump month and year menus that read as plain text.
            Menu {
                ForEach(Array(calendar.monthSymbols.enumerated()), id: \.offset) { index, name in
                    Button(name) { set(month: index + 1) }
                }
            } label: {
                Text(calendar.monthSymbols[calendar.component(.month, from: month) - 1])
                    .font(.headline)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Menu {
                ForEach(yearRange, id: \.self) { year in
                    Button(String(year)) { set(year: year) }
                }
            } label: {
                Text(verbatim: "\(calendar.component(.year, from: month))")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            if !isViewingCurrentMonth {
                Button { month = Date() } label: {
                    Text("Today").font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .help("Jump to this month")
            }

            HStack(spacing: 2) {
                Button { shift(by: -1) } label: { Image(systemName: "chevron.left") }
                Button { shift(by: 1) } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.borderless)
            .font(.callout.weight(.semibold))
        }
    }

    private var isViewingCurrentMonth: Bool {
        calendar.isDate(month, equalTo: Date(), toGranularity: .month)
    }

    private var yearRange: [Int] {
        let now = calendar.component(.year, from: Date())
        return Array((now - 15)...(now + 1)).reversed()
    }

    private func set(month: Int) {
        var comps = calendar.dateComponents([.year], from: self.month)
        comps.month = month
        comps.day = 1
        if let date = calendar.date(from: comps) { self.month = date }
    }

    private func set(year: Int) {
        var comps = calendar.dateComponents([.month], from: self.month)
        comps.year = year
        comps.day = 1
        if let date = calendar.date(from: comps) { self.month = date }
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
            // Fixed-size circle keeps every day the same width and centered; days
            // with recordings get a short accent underline just beneath the date.
            Text("\(calendar.component(.day, from: day))")
                .font(.callout)
                .fontWeight(isToday ? .bold : .regular)
                .foregroundStyle(isToday ? Color.white : .primary)
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(fillColor(isToday: isToday, isSelected: isSelected))
                }
                .overlay(alignment: .bottom) {
                    if hasEntries {
                        Capsule()
                            .fill(isToday ? Color.white.opacity(0.8) : settings.accent.opacity(0.55))
                            .frame(width: 13, height: 1.5)
                            .offset(y: -5)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 34)
        }
        .buttonStyle(.plain)
        .disabled(!hasEntries)
        .opacity(hasEntries || isToday ? 1 : 0.4)
    }

    private func fillColor(isToday: Bool, isSelected: Bool) -> Color {
        if isToday {
            return settings.accent
        }
        return isSelected ? settings.accent.opacity(0.22) : .clear
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
