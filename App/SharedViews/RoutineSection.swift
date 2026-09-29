import HabitKit
import HabitStore
import SwiftUI

/// Asks when Health shows a linked habit already happened today. Set on the iPhone, the only
/// device that reads Health.
struct HealthMatch: Equatable {
    let find: @MainActor (UUID) async -> Date?

    /// One per app, reading the model it was made with, so any two are the same. Comparing
    /// equal keeps the environment from redrawing every row when the root view redraws.
    static func == (lhs: HealthMatch, rhs: HealthMatch) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var healthMatch: HealthMatch?
}

/// One routine on the Today screen. Every habit is done, skipped, or undone from here.
///
/// Swipe right to do a habit, left to skip it. Any habit due today can be done, in any order,
/// and the next one in sequence is marked, since that is the one the widget and Siri tick.
struct RoutineSection: View {
    @Environment(AppModel.self) private var model
    let routine: RoutineSlot
    let add: () -> Void

    var body: some View {
        let habits = model.habits(in: routine)
        let states = model.states(in: routine)
        let due = states.values.filter { $0 != .notDue }.count
        let done = states.values.filter { $0 == .done }.count
        Section {
            ForEach(habits, id: \.habit.id) { history in
                HabitListRow(history: history, state: states[history.habit.id] ?? .notDue)
            }
            .onMove { source, destination in
                Task { await model.move(in: routine, from: source, to: destination) }
            }

            AddHabitRow(routine: routine, add: add)
                .id(AddHabitRow.scrollID(routine))
        } header: {
            HStack {
                Label(routine.title, systemImage: routine.symbol)
                Spacer()
                if due > 0 {
                    Text(done == due ? "All done" : "\(done) of \(due)")
                        .monospacedDigit()
                        .accessibilityLabel(done == due ? "All done" : "\(done) of \(due) done")
                }
            }
        }
    }
}

/// One habit on Today, with its swipes. Tapping opens the habit.
struct HabitListRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.healthMatch) private var healthMatch
    @Environment(\.scenePhase) private var scenePhase
    let history: HabitHistory
    let state: StepState

    /// What Health reported for this habit, and on which day, so an answer from another day
    /// is never offered.
    @State private var match: (day: DayKey, at: Date)?
    /// Counts this row's own completions, so the haptic answers a swipe here and not a tick
    /// that arrived from the watch, iCloud or the widget.
    @State private var completedHere = 0

    var body: some View {
        NavigationLink(value: history.habit.id) {
            HabitRow(history: history, state: state, offer: offer)
        }
        .accessibilityValue(HabitRow.label(for: state, history: history))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            // With a Health match, the full swipe counts it at Health's time, since that is
            // when it happened. Done now stays one step further in.
            if let offer {
                action(.complete(occurredAt: offer), "Count it", "heart.text.square").tint(.pink)
            }
            if state.canComplete {
                action(.complete(), "Done", "checkmark").tint(.green)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            trailingAction
        }
        .contextMenu {
            if let offer { action(.complete(occurredAt: offer), "Count it", "heart.text.square") }
            if state.canComplete { action(.complete(), "Done", "checkmark") }
            trailingAction
        }
        .sensoryFeedback(.success, trigger: completedHere)
        // Asked while the person is looking, which answers at once, unlike background
        // delivery. Again on coming back to the app, which is when a dose has usually just
        // been logged. An offer is only an offer: nothing is counted until it is chosen.
        .task(id: HealthCheck(habitID: history.habit.id, day: history.today,
                              isNext: state == .next, isActive: scenePhase == .active)) {
            match = nil
            guard state == .next, scenePhase == .active, let healthMatch,
                  model.bindings[history.habit.id] != nil else { return }
            let day = history.today
            guard let found = await healthMatch.find(history.habit.id), !Task.isCancelled else { return }
            match = (day, found)
        }
    }

    private struct HealthCheck: Hashable {
        let habitID: UUID
        let day: DayKey
        let isNext: Bool
        let isActive: Bool
    }

    private var offer: Date? {
        guard state.canComplete, let match, match.day == history.today else { return nil }
        return match.at
    }

    /// Skip for a habit still to do, and the way back for one already passed.
    @ViewBuilder
    private var trailingAction: some View {
        switch state {
        case .next, .waiting: action(.skip, "Skip", "forward.fill").tint(.orange)
        case .done: action(.reopen, "Not done", "arrow.uturn.backward").tint(.gray)
        case .skipped: action(.reopen, "Unskip", "arrow.uturn.backward").tint(.gray)
        case .notDue: EmptyView()
        }
    }

    private func action(_ action: ListAction, _ title: String, _ symbol: String) -> some View {
        Button(title, systemImage: symbol) {
            Task {
                let applied = await model.apply(action, to: history.habit.id)
                if applied, case .complete = action { completedHere += 1 }
            }
        }
        .accessibilityIdentifier("\(title).\(history.habit.title)")
    }
}

struct HabitRow: View {
    let history: HabitHistory
    let state: StepState
    /// When Health shows this habit happened today, if it does and it is not yet counted.
    var offer: Date?

    var body: some View {
        HStack(spacing: 12) {
            HabitIconView(symbol: HabitIcons.symbol(for: history.habit),
                          tint: HabitIcons.tint(for: history.habit), state: state)

            VStack(alignment: .leading, spacing: 2) {
                Text(history.habit.title)
                    .fontWeight(state == .next ? .semibold : .regular)
                    .foregroundStyle(state == .notDue || state == .skipped ? .secondary : .primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                if let offer {
                    Label("Health shows it at \(offer.formatted(date: .omitted, time: .shortened)). Swipe right to count it.",
                          systemImage: "heart.text.square")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.pink)
                        .padding(.top, 2)
                }
            }
            Spacer()
            if history.habit.completionSource == .automatic {
                Image(systemName: "heart.text.square").foregroundStyle(.pink).accessibilityLabel("Linked to Health")
            }
        }
    }

    static func label(for state: StepState, history: HabitHistory) -> String {
        switch state {
        case .done: "Done"
        case .skipped: "Skipped"
        case .next: "Next"
        case .waiting: "To do"
        case .notDue: history.currentState == .paused ? "Paused" : "Rest day"
        }
    }

    private var subtitle: String {
        switch history.currentState {
        case .paused: return "Paused"
        case .archived: return "Archived"
        case .active: break
        }
        switch state {
        case .notDue: return "Rest day"
        case .skipped: return "Skipped. You can still mark it done."
        case .next:
            if let small = history.habit.twoMinuteVersion { return "Next. Start with: \(small)" }
            if let cue = history.habit.cue { return "Next. \(cue)" }
            return "Next. \(history.streak.caption)"
        case .done, .waiting: return history.streak.caption
        }
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

    /// Where Today scrolls for a routine with no habits yet.
    static func scrollID(_ routine: RoutineSlot) -> String { "add.\(routine.rawValue)" }

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
                    let waiting = model.waitingOn(routine).count
                    if waiting > 1 {
                        Label("Next habit unlocks when your \(waiting) newest habits bed in", systemImage: "lock")
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
