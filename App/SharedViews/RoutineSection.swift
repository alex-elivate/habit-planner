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

    @State private var settingUp = false

    var body: some View {
        switch model.gate(for: routine) {
        case .open where model.isSettingUp(routine):
            // Any number of habits can join on the first day, so the habits somebody already
            // does can all come in together.
            let empty = model.habits(in: routine).isEmpty
            if !empty {
                Text("Setting up today. Add every habit you already do. From tomorrow, a new habit can join once all of these have bedded in.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            // The sheet hangs off this one row. On the group, a list gives every row its own copy.
            Button(empty ? "Set up your \(routine.title.lowercased()) routine" : "Add more habits",
                   systemImage: "list.bullet") { settingUp = true }
                .sheet(isPresented: $settingUp) {
                    NavigationStack { RoutineSetupView(routine: routine) }
                        .sheetMinimumSize(width: 480, height: 540)
                }
            Button("Add a habit with details", systemImage: "plus", action: add)
        case .open:
            Button(model.planned.active(for: routine).map { "Add \($0.title)" } ?? "Add a habit",
                   systemImage: "plus", action: add)
            // Still editable once unlocked, so a plan can be changed or dropped without adding it.
            if model.planned.active(for: routine) != nil { PlannedHabitRow(routine: routine) }
        case .unreadable:
            Label("Some habits were saved by a newer version of the app. Update this device to add habits.",
                  systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .blocked(let judged):
            if let habit = model.history(for: judged.habitID)?.habit {
                VStack(alignment: .leading, spacing: 6) {
                    if let waiting = model.startingHabitsBeddingIn(routine), waiting > 1 {
                        Label("Next habit unlocks when your \(waiting) starting habits bed in", systemImage: "lock")
                            .font(.subheadline)
                        Text("\(habit.title) has the furthest to go.").font(.caption)
                    } else {
                        Label("Next habit unlocks when \(habit.title) beds in", systemImage: "lock")
                            .font(.subheadline)
                    }
                    ProgressView(value: judged.repetitionProgress)
                    Text(judged.explanation).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            PlannedHabitRow(routine: routine)
        }
    }
}

/// The habit this routine will add once it unlocks, which the widgets show as the thing to
/// work towards.
struct PlannedHabitRow: View {
    @Environment(AppModel.self) private var model
    let routine: RoutineSlot
    @State private var editing = false

    var body: some View {
        let plan = model.planned.active(for: routine)
        Button {
            editing = true
        } label: {
            if let plan {
                LabeledContent("Planned next", value: plan.title)
            } else {
                Label("Plan the next habit", systemImage: "square.and.pencil")
            }
        }
        .accessibilityIdentifier("plan.\(routine.rawValue)")
        .sheet(isPresented: $editing) {
            NavigationStack { PlanHabitView(routine: routine, title: plan?.title ?? "") }
                .sheetMinimumSize(width: 440, height: 300)
        }
    }
}

struct PlanHabitView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let routine: RoutineSlot
    @State var title: String
    private let original: String

    init(routine: RoutineSlot, title: String) {
        self.routine = routine
        self._title = State(initialValue: title)
        self.original = title
    }

    var body: some View {
        Form {
            Section {
                TextField("Habit", text: $title, prompt: Text("Meditate"))
                    .font(.headline)
                    .accessibilityIdentifier("plan.title")
            } footer: {
                Text("Something to work towards. It is added to your \(routine.title.lowercased()) routine once the newest habit there beds in, and your widgets show it until then.")
            }
            if !original.isEmpty {
                Section {
                    Button("Clear plan", role: .destructive) {
                        Task {
                            await model.clearPlan(for: routine)
                            dismiss()
                        }
                    }
                }
            }
        }
        // Already the phone's style. On the Mac the default lays sections out bare, with no
        // room for footers or long labels.
        .formStyle(.grouped)
        .navigationTitle("Next habit")
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        await model.plan(title, for: routine)
                        dismiss()
                    }
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || title == original)
            }
        }
    }
}
