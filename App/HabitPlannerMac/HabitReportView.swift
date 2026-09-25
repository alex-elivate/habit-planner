import HabitKit
import SwiftUI

/// One habit: its calendar, its rates, and what can be done to it.
struct HabitReportView: View {
    @Environment(AppModel.self) private var model
    let habitID: UUID

    @State private var editing = false
    @State private var confirmingArchive = false
    @State private var shownMonth: (year: Int, month: Int)?

    var body: some View {
        if let history = model.history(for: habitID) {
            let report = HabitReport(history)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(history)
                    MonthCalendar(report: report, month: month(for: report))
                    HStack(alignment: .top, spacing: 32) {
                        PeriodTable(title: "Weeks", periods: report.weeks(6), label: weekLabel)
                        PeriodTable(title: "Months", periods: report.months(6), label: monthLabel)
                    }
                    if let assessment = judged(history) {
                        GroupBox("Lock-in") {
                            VStack(alignment: .leading, spacing: 6) {
                                ProgressView(value: assessment.repetitionProgress)
                                Text(assessment.explanation).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .navigationTitle(history.habit.title)
            .toolbar { actions(history) }
            .sheet(isPresented: $editing) {
                NavigationStack { HabitEditorView(mode: .edit(habitID), habit: history.habit) }
                    .frame(minWidth: 460, minHeight: 440)
            }
            .confirmationDialog("Archive \(history.habit.title)?", isPresented: $confirmingArchive) {
                Button("Archive", role: .destructive) {
                    Task { await model.setState(.archived, for: habitID) }
                }
            } message: {
                Text("Its history stays. Bringing it back later counts as adding a habit.")
            }
        } else {
            ContentUnavailableView("This habit is gone", systemImage: "questionmark")
        }
    }

    private func header(_ history: HabitHistory) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(history.habit.routine.title) routine · \(scheduleText(history.habit.schedule))")
                .foregroundStyle(.secondary)
            Text(stateText(history)).font(.title3.weight(.semibold))
            if let cue = history.habit.cue { Text(cue).foregroundStyle(.secondary) }
        }
    }

    private func stateText(_ history: HabitHistory) -> String {
        switch history.currentState {
        case .paused: "Paused"
        case .archived: "Archived"
        case .active: history.isDueToday ? history.streak.caption : "Rest day. \(history.streak.caption)"
        }
    }

    private func judged(_ history: HabitHistory) -> LockInGate.Assessment? {
        guard LockInGate.judged(in: history.habit.routine, histories: model.histories)?.habit.id == habitID
        else { return nil }
        return LockInGate.assess(history)
    }

    @ToolbarContentBuilder
    private func actions(_ history: HabitHistory) -> some ToolbarContent {
        ToolbarItemGroup {
            switch history.currentState {
            case .active:
                Button("Pause", systemImage: "pause") { Task { await model.setState(.paused, for: habitID) } }
                Button("Archive", systemImage: "archivebox") { confirmingArchive = true }
            case .paused:
                Button("Resume", systemImage: "play") { Task { await model.setState(.active, for: habitID) } }
                Button("Archive", systemImage: "archivebox") { confirmingArchive = true }
            case .archived:
                Button("Restore", systemImage: "arrow.uturn.backward") {
                    Task { await model.setState(.active, for: habitID) }
                }
                .disabled(!model.canRestore(habitID))
                .help(model.canRestore(habitID) ? "Restore" : "Restoring waits until the routine's newest habit beds in")
            }
            Button("Edit", systemImage: "pencil") { editing = true }
                .keyboardShortcut("e", modifiers: .command)
        }
    }

    // MARK: - Month navigation

    private func month(for report: HabitReport) -> Binding<(year: Int, month: Int)> {
        Binding(
            get: { shownMonth ?? (report.today.year, report.today.month) },
            set: { shownMonth = $0 }
        )
    }

    private func weekLabel(_ start: DayKey) -> String {
        start.start(in: .current).formatted(.dateTime.month(.abbreviated).day())
    }

    private func monthLabel(_ start: DayKey) -> String {
        start.start(in: .current).formatted(.dateTime.month(.wide).year())
    }

    private func scheduleText(_ schedule: Schedule) -> String {
        switch schedule {
        case .daily: return "Every day"
        case .daysOfWeek(let days):
            return Weekday.allCases.filter(days.contains).map(\.shortName).joined(separator: " ")
        }
    }
}

/// A month as a seven-column grid, Monday first, each day coloured by its mark.
struct MonthCalendar: View {
    let report: HabitReport
    @Binding var month: (year: Int, month: Int)

    private let columns = Array(repeating: GridItem(.flexible(minimum: 28, maximum: 44), spacing: 4), count: 7)

    var body: some View {
        let days = report.month(year: month.year, month: month.month)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Previous month", systemImage: "chevron.left") { step(-1) }
                    .labelStyle(.iconOnly)
                Button("Next month", systemImage: "chevron.right") { step(1) }
                    .labelStyle(.iconOnly)
                    .disabled(month.year == report.today.year && month.month == report.today.month)
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(["M", "T", "W", "T", "F", "S", "S"].indices, id: \.self) { index in
                    Text(["M", "T", "W", "T", "F", "S", "S"][index])
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(0..<leadingBlanks(days.first?.day), id: \.self) { _ in Color.clear.frame(height: 28) }
                ForEach(days, id: \.day) { entry in
                    DayCell(day: entry.day.day, mark: entry.mark, isToday: entry.day == report.today)
                }
            }
            .frame(maxWidth: 340)
            Legend()
        }
    }

    private var title: String {
        DayKey(year: month.year, month: month.month, day: 1).start(in: .current)
            .formatted(.dateTime.month(.wide).year())
    }

    private func step(_ delta: Int) {
        var m = month.month + delta, y = month.year
        if m == 0 { m = 12; y -= 1 }
        if m == 13 { m = 1; y += 1 }
        month = (y, m)
    }

    private func leadingBlanks(_ first: DayKey?) -> Int {
        guard let first else { return 0 }
        return (first.weekday.rawValue + 5) % 7
    }
}

private struct DayCell: View {
    let day: Int
    let mark: HabitReport.Mark
    let isToday: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(mark.fill)
            .overlay {
                Text("\(day)").font(.caption2.monospacedDigit()).foregroundStyle(mark.textStyle)
            }
            .overlay {
                if isToday { RoundedRectangle(cornerRadius: 5).strokeBorder(.primary, lineWidth: 1.5) }
            }
            .frame(height: 28)
            .accessibilityLabel("\(day), \(mark.name)")
    }
}

private struct Legend: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach([HabitReport.Mark.done, .missed, .rest, .paused, .pending], id: \.self) { mark in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3).fill(mark.fill).frame(width: 12, height: 12)
                    Text(mark.name).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension HabitReport.Mark {
    var name: String {
        switch self {
        case .beforeStart: "Before it started"
        case .done: "Done"
        case .missed: "Missed"
        case .rest: "Rest day"
        case .paused: "Paused"
        case .archived: "Archived"
        case .pending: "Today, not yet done"
        case .future: "Ahead"
        }
    }

    var fill: AnyShapeStyle {
        switch self {
        case .done: AnyShapeStyle(Color.accentColor)
        case .missed: AnyShapeStyle(Color.red.opacity(0.55))
        case .pending: AnyShapeStyle(Color.accentColor.opacity(0.25))
        case .paused: AnyShapeStyle(Color.orange.opacity(0.35))
        case .rest, .archived: AnyShapeStyle(.quaternary)
        case .beforeStart, .future: AnyShapeStyle(.clear)
        }
    }

    var textStyle: AnyShapeStyle {
        switch self {
        case .done, .missed: AnyShapeStyle(Color.white)
        case .beforeStart, .future: AnyShapeStyle(.tertiary)
        default: AnyShapeStyle(.primary)
        }
    }
}

/// Done out of scheduled for each period, oldest at the top.
struct PeriodTable: View {
    let title: String
    let periods: [HabitReport.Period]
    let label: (DayKey) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(periods, id: \.start) { period in
                    GridRow {
                        Text(label(period.start)).foregroundStyle(.secondary)
                        Text(period.scheduled == 0 ? "–" : "\(period.completed) of \(period.scheduled)")
                            .monospacedDigit()
                        Text(period.rate.map { "\(Int(($0 * 100).rounded()))%" } ?? "")
                            .monospacedDigit()
                            .foregroundStyle(rateStyle(period.rate))
                    }
                }
            }
        }
    }

    /// Below the gate's 85% reads as a warning, since that is the line that matters.
    private func rateStyle(_ rate: Double?) -> AnyShapeStyle {
        guard let rate else { return AnyShapeStyle(.secondary) }
        return rate >= LockInGate.requiredRate ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.orange)
    }
}

extension Weekday {
    var shortName: String {
        switch self {
        case .sunday: "Sun"
        case .monday: "Mon"
        case .tuesday: "Tue"
        case .wednesday: "Wed"
        case .thursday: "Thu"
        case .friday: "Fri"
        case .saturday: "Sat"
        }
    }
}
