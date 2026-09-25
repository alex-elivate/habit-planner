import HabitKit
import SwiftUI

/// Every habit's completion rate by week and month, and its current streak.
///
/// One column per period, dated, so each figure has a heading. Double-click a row, or press
/// Return, to open that habit's report.
struct RatesView: View {
    @Environment(AppModel.self) private var model
    let open: (UUID) -> Void

    @State private var selection: UUID?

    private static let weekCount = 4
    private static let monthCount = 3

    private struct Row: Identifiable {
        let history: HabitHistory
        let weeks: [HabitReport.Period]
        let months: [HabitReport.Period]
        var id: UUID { history.habit.id }
    }

    var body: some View {
        let rows = RoutineSlot.allCases.flatMap { model.habits(in: $0) }.map { history in
            let report = HabitReport(history)
            return Row(history: history, weeks: report.weeks(Self.weekCount), months: report.months(Self.monthCount))
        }
        // Every row shares one today, so the first row's periods date the columns.
        let weekStarts = rows.first?.weeks.map(\.start) ?? []
        let monthStarts = rows.first?.months.map(\.start) ?? []

        Table(rows, selection: $selection) {
            TableColumn("Habit") { row in
                VStack(alignment: .leading) {
                    Text(row.history.habit.title)
                    Text(row.history.habit.routine.title).font(.caption).foregroundStyle(.secondary)
                }
            }
            .width(min: 150, ideal: 190)
            TableColumn("Streak") { row in
                HStack(spacing: 4) {
                    Text("\(row.history.streak.length)").monospacedDigit()
                    if row.history.streak.isAtRisk {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("Missed once. Don't miss twice.")
                    }
                }
            }
            .width(min: 50, ideal: 60)
            TableColumnForEach(weekStarts.indices, id: \.self) { index in
                TableColumn("Wk \(weekStarts[index].start(in: .current).formatted(.dateTime.month(.abbreviated).day()))") { row in
                    RateCell(period: row.weeks[index])
                }
                .width(min: 64, ideal: 72)
            }
            TableColumnForEach(monthStarts.indices, id: \.self) { index in
                TableColumn(monthStarts[index].start(in: .current).formatted(.dateTime.month(.wide))) { row in
                    RateCell(period: row.months[index])
                }
                .width(min: 70, ideal: 84)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { ids in
            if let id = ids.first { open(id) }
        }
        .navigationTitle("Completion rates")
        .overlay {
            if rows.isEmpty { ContentUnavailableView("No habits yet", systemImage: "tablecells") }
        }
    }
}

/// A rate, in orange below the gate's 85%, since that is the line that matters.
private struct RateCell: View {
    let period: HabitReport.Period

    var body: some View {
        Text(period.rate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .foregroundStyle(period.rate.map { $0 >= LockInGate.requiredRate } ?? true
                             ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.orange))
            .help(period.scheduled == 0 ? "Nothing scheduled" : "\(period.completed) of \(period.scheduled)")
    }
}

/// For each routine, the habit the gate is judging and exactly where it stands.
struct LockInView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            ForEach(RoutineSlot.allCases) { routine in
                Section {
                    content(for: routine)
                } header: {
                    Label(routine.title, systemImage: routine.symbol)
                }
            }
            Section {
                Text("A habit beds in after \(LockInGate.requiredOccurrences) scheduled sessions at \(Int(LockInGate.requiredRate * 100))% or better, with no two misses in a row in the last \(LockInGate.doubleMissWindowDays) days. Only then can the routine take another.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Lock-in")
    }

    @ViewBuilder private func content(for routine: RoutineSlot) -> some View {
        let planned = model.planned.active(for: routine)?.title
        switch model.gate(for: routine) {
        case .open:
            LabeledContent("Status", value: model.habits(in: routine).isEmpty ? "No habits yet" : "Open. A habit can be added.")
            if let planned { LabeledContent("Planned next", value: planned) }
        case .unreadable:
            Text("Some habits were saved by a newer version of the app. Update this Mac to see where the routine stands.")
        case .blocked(let assessment):
            if let habit = model.history(for: assessment.habitID)?.habit {
                LabeledContent("Bedding in", value: habit.title)
                LabeledContent("Sessions",
                               value: "\(min(assessment.elapsedOccurrences, assessment.requiredOccurrences)) of \(assessment.requiredOccurrences)")
                LabeledContent("Rate", value: assessment.rate.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
                ProgressView(value: assessment.repetitionProgress)
                Text(assessment.explanation).foregroundStyle(.secondary)
                LabeledContent("Planned next", value: planned ?? "Not planned yet")
                NavigationLink("Open \(habit.title)", value: habit.id)
            }
        }
    }
}
