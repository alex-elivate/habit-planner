import HabitKit
import SwiftUI

struct HabitEditorView: View {
    enum Mode {
        case new(RoutineSlot)
        case edit(UUID)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    @State private var draft: HabitDraft
    @State private var saving = false
    @State private var refusal: String?

    init(mode: Mode, habit: Habit? = nil) {
        self.mode = mode
        switch mode {
        case .new(let routine): _draft = State(initialValue: HabitDraft(routine: routine))
        case .edit: _draft = State(initialValue: habit.map(HabitDraft.init) ?? HabitDraft())
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Habit", text: $draft.title, prompt: Text("Stretch"))
                    .font(.headline)
            } footer: {
                if case .new(let routine) = mode {
                    Text("Joins the end of your \(routine.title.lowercased()) routine. Drag to reorder later.")
                }
            }

            Section {
                TextField("Cue", text: $draft.cue, prompt: Text("After I pour my coffee"), axis: .vertical)
                TextField("Two-minute version", text: $draft.twoMinuteVersion,
                          prompt: Text("Touch my toes once"), axis: .vertical)
                TextField("Identity", text: $draft.identityStatement,
                          prompt: Text("I'm someone who moves every morning"), axis: .vertical)
            } footer: {
                Text("The cue anchors this habit to something you already do. The two-minute version is so small you cannot say no. The identity is who each repetition votes for.")
            }

            ScheduleSection(schedule: $draft.schedule)

            if let refusal {
                Section { Text(refusal).foregroundStyle(.red) }
            }
        }
        .navigationTitle(isNew ? "New habit" : "Edit habit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save", action: save)
                    .disabled(!draft.isValid || saving)
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private var isNew: Bool {
        if case .new = mode { return true }
        return false
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            switch mode {
            case .new:
                do {
                    try await model.add(draft)
                    dismiss()
                } catch {
                    refusal = error.localizedDescription
                }
            case .edit(let id):
                await model.update(id, from: draft)
                dismiss()
            }
        }
    }
}

struct ScheduleSection: View {
    @Binding var schedule: Schedule

    var body: some View {
        Section {
            Picker("Repeats", selection: isDaily) {
                Text("Every day").tag(true)
                Text("Chosen days").tag(false)
            }
            .pickerStyle(.segmented)

            if case .daysOfWeek(let days) = schedule {
                HStack {
                    ForEach(Weekday.allCases, id: \.self) { day in
                        let on = days.contains(day)
                        Button(day.initial) { toggle(day) }
                            .buttonStyle(.bordered)
                            .tint(on ? .accentColor : .secondary)
                            .fontWeight(on ? .bold : .regular)
                            .accessibilityLabel(day.name)
                            .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
        } header: {
            Text("Schedule")
        } footer: {
            Text("A habit is judged on the sessions it was scheduled for, so three days a week is held to the same standard as every day.")
        }
    }

    private var isDaily: Binding<Bool> {
        Binding(
            get: { schedule == .daily },
            set: { schedule = $0 ? .daily : .daysOfWeek([.monday, .wednesday, .friday]) }
        )
    }

    private func toggle(_ day: Weekday) {
        guard case .daysOfWeek(var days) = schedule else { return }
        if days.contains(day) { days.remove(day) } else { days.insert(day) }
        schedule = .daysOfWeek(days)
    }
}

extension Weekday {
    private var symbolIndex: Int { rawValue - 1 }
    var name: String { Calendar.current.weekdaySymbols[symbolIndex] }
    var initial: String { Calendar.current.veryShortWeekdaySymbols[symbolIndex] }
}
