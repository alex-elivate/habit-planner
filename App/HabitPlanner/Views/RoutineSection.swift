import HabitKit
import SwiftUI

struct RoutineSection: View {
    @Environment(AppModel.self) private var model
    let routine: RoutineSlot
    let start: (RoutineSlot) -> Void
    let add: () -> Void

    var body: some View {
        let habits = model.habits(in: routine)
        Section {
            if !habits.isEmpty { startButton }

            ForEach(habits, id: \.habit.id) { history in
                NavigationLink(value: history.habit.id) {
                    HabitRow(history: history)
                }
            }
            .onMove { source, destination in
                Task { await model.move(in: routine, from: source, to: destination) }
            }

            AddHabitRow(routine: routine, add: add)
        } header: {
            Label(routine.title, systemImage: routine.symbol)
        }
    }

    @ViewBuilder private var startButton: some View {
        let run = model.runsToday[routine]
        let remaining = model.hasWorkRemaining(in: routine)
        Button {
            start(routine)
        } label: {
            HStack {
                Image(systemName: remaining ? "play.fill" : "checkmark")
                Text(!remaining ? "Done for today" : (run?.startedAt != nil ? "Resume" : "Start \(routine.title.lowercased()) routine"))
                    .fontWeight(.semibold)
                Spacer()
            }
        }
        .disabled(!remaining)
    }
}

struct HabitRow: View {
    @Environment(AppModel.self) private var model
    let history: HabitHistory

    var body: some View {
        HStack(spacing: 12) {
            if history.isDueToday {
                Button {
                    Task { await model.toggleToday(history.habit.id) }
                } label: {
                    Image(systemName: history.isCompletedToday ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(history.isCompletedToday ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(history.isCompletedToday ? "Mark not done" : "Mark done")
            } else {
                Image(systemName: history.currentState == .paused ? "pause.circle" : "moon.zzz")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(history.habit.title)
                    .foregroundStyle(history.isDueToday ? .primary : .secondary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if history.habit.completionSource == .automatic {
                Image(systemName: "heart.text.square").foregroundStyle(.pink).accessibilityLabel("Linked to Health")
            }
        }
    }

    private var subtitle: String {
        switch history.currentState {
        case .paused: return "Paused"
        case .archived: return "Archived"
        case .active: break
        }
        if !history.isDueToday { return "Rest day" }
        return history.streak.caption
    }
}

extension StreakState {
    var caption: String {
        switch self {
        case .healthy(let length): length == 0 ? "New" : "\(length) in a row"
        case .recovery: "Missed once. Don't miss twice."
        case .broken: "Starting again"
        }
    }
}

/// Adds a habit, or explains how far the newest one has to go before the routine can grow.
struct AddHabitRow: View {
    @Environment(AppModel.self) private var model
    let routine: RoutineSlot
    let add: () -> Void

    var body: some View {
        let gate = model.gate(for: routine)
        if gate.decision.isOpen {
            Button("Add a habit", systemImage: "plus", action: add)
        } else if let judged = gate.judged, let habit = model.history(for: judged.habitID)?.habit {
            VStack(alignment: .leading, spacing: 6) {
                Label("Next habit unlocks when \(habit.title) beds in", systemImage: "lock")
                    .font(.subheadline)
                ProgressView(value: judged.repetitionProgress)
                Text(judged.explanation).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }
}

extension LockInGate.Assessment {
    /// What stands between this habit and the next, in the terms the person can act on.
    var explanation: String {
        let sessions = "\(min(elapsedOccurrences, requiredOccurrences)) of \(requiredOccurrences) sessions"
        let rateText = rate.map { "\(Int(($0 * 100).rounded()))%" }
        let needed = "\(Int((requiredRate * 100).rounded()))%"
        switch decision {
        case .open:
            return "Bedded in."
        case .blocked(.notEnoughHistory):
            return rateText.map { "\(sessions), \($0) so far." } ?? "\(sessions)."
        case .blocked(.rateTooLow):
            return "\(sessions) done at \(rateText ?? "–"). Needs \(needed)."
        case .blocked(.recentDoubleMiss(let day)):
            // The pair counts while its second miss is within the window, so it drops out
            // the day after the window passes it.
            let missed = day.start(in: .current).formatted(.dateTime.month().day())
            let clears = day.advanced(by: LockInGate.doubleMissWindowDays + 1)
                .start(in: .current).formatted(.dateTime.month().day())
            return "Missed twice in a row on \(missed). That stops counting on \(clears)."
        }
    }
}
