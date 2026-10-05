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
    /// The field to open on, when the editor was opened to change one thing.
    let focus: HabitEditorFocus?
    @State private var draft: HabitDraft
    @State private var saving = false
    @State private var refusal: String?
    @FocusState private var focused: HabitEditorFocus?

    init(mode: Mode, habit: Habit? = nil, focus: HabitEditorFocus? = nil) {
        self.mode = mode
        self.focus = focus
        switch mode {
        case .new(let routine): _draft = State(initialValue: HabitDraft(routine: routine))
        case .edit: _draft = State(initialValue: habit.map(HabitDraft.init) ?? HabitDraft())
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            form
                // The field asked for gets focus when the editor appears. Also set once the
                // sheet has settled, since focus set while it is still animating in can be
                // dropped.
                .defaultFocus($focused, focus == .schedule ? nil : focus)
                .task {
                    guard let focus else { return }
                    // After the sheet has finished presenting. Focus set while it is still
                    // animating in is dropped.
                    try? await Task.sleep(for: .milliseconds(700))
                    if focus == .schedule {
                        withAnimation { proxy.scrollTo(HabitEditorFocus.schedule, anchor: .top) }
                    } else {
                        focused = focus
                    }
                }
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Habit", text: $draft.title, prompt: Text("Stretch"))
                    .font(.headline)
                NavigationLink {
                    IconPickerView(symbolName: $draft.symbolName, tint: $draft.tint,
                                   title: draft.title, routine: draft.routine)
                } label: {
                    HStack {
                        Text("Icon")
                        Spacer()
                        HabitIconView(symbol: HabitIcons.symbol(draft.symbolName, title: draft.title,
                                                                routine: draft.routine),
                                      tint: draft.tint ?? .default(for: draft.routine), size: 32)
                    }
                }
            } footer: {
                if case .new(let routine) = mode {
                    Text("Joins the end of your \(routine.title.lowercased()) routine. Drag to reorder later.")
                }
            }

            Section {
                TextField("Cue", text: $draft.cue, prompt: Text("After I pour my coffee"), axis: .vertical)
                    .focused($focused, equals: .cue)
                    .accessibilityLabel("Cue")
                    .accessibilityIdentifier("editor.cue")
                TextField("Two-minute version", text: $draft.twoMinuteVersion,
                          prompt: Text("Touch my toes once"), axis: .vertical)
                    .focused($focused, equals: .twoMinuteVersion)
                    .accessibilityLabel("Two-minute version")
                    .accessibilityIdentifier("editor.twoMinuteVersion")
                TextField("Identity", text: $draft.identityStatement,
                          prompt: Text("I'm someone who moves every morning"), axis: .vertical)
                    .accessibilityLabel("Identity")
            } footer: {
                Text("The cue anchors this habit to something you already do. The two-minute version is so small you cannot say no. The identity is who each repetition votes for.")
            }

            ScheduleSection(schedule: $draft.schedule)
                .id(HabitEditorFocus.schedule)

            if let refusal {
                Section { Text(refusal).foregroundStyle(.red) }
            }
        }
        // Already the phone's style. On the Mac the default lays sections out bare, with no
        // room for footers or long labels.
        .formStyle(.grouped)
        .navigationTitle(isNew ? "New habit" : "Edit habit")
        .inlineNavigationTitle()
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
        .onAppear {
            // A new habit starts from the routine's plan, if it has one. Only when the title is
            // still empty, so reopening the sheet never overwrites what was typed.
            if case .new(let routine) = mode, draft.title.isEmpty,
               let plan = model.planned.active(for: routine) {
                draft.title = plan.title
            }
        }
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
                do {
                    try await model.update(id, from: draft)
                    dismiss()
                } catch {
                    refusal = error.localizedDescription
                }
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
