import HabitKit
import SwiftUI

/// Enters the habits a routine already has, in the order they are done, all at once.
///
/// Only offered while the routine is in setup, which is the only time the gate lets more than
/// one habit join in a day. See `LockInGate.startingSet`. Each habit starts with a title and a
/// daily schedule, and anything more is added from the habit itself afterwards.
struct RoutineSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let routine: RoutineSlot
    /// The routine to set up after this one. Set on first launch, which walks through both.
    var then: RoutineSlot?
    /// Closes the whole setup. Passed to the second routine, whose own dismiss would only go
    /// back to the first.
    var close: (() -> Void)?

    private struct Entry: Identifiable {
        let id = UUID()
        var title = ""
    }

    /// Part of the first-launch walk through, where a routine may be left empty for now.
    private var isFirstLaunch: Bool { then != nil || close != nil }

    private func leave() {
        if let close { close() } else { dismiss() }
    }

    @State private var entries = [Entry()]
    @State private var saving = false
    @State private var savedAny = false
    @State private var showingNext = false
    @FocusState private var focused: UUID?

    private var titles: [String] {
        entries.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var body: some View {
        Form {
            let existing = model.habits(in: routine)
            if !existing.isEmpty {
                Section("Already in this routine") {
                    ForEach(existing, id: \.habit.id) { Text($0.habit.title) }
                }
            }

            Section {
                ForEach($entries) { $entry in
                    TextField("Habit", text: $entry.title, prompt: Text(example(for: entry.id)))
                        .focused($focused, equals: entry.id)
                        .submitLabel(.next)
                        .onSubmit { addEntry() }
                }
                .onDelete { offsets in
                    entries.remove(atOffsets: offsets)
                    if entries.isEmpty { entries = [Entry()] }
                }
                .onMove { entries.move(fromOffsets: $0, toOffset: $1) }
                Button("Add another", systemImage: "plus", action: addEntry)
            } header: {
                Text("In the order you do them")
            } footer: {
                Text(footer)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("\(routine.title) routine")
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(then == nil ? "Cancel" : "Not now", action: leave)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(then == nil ? "Done" : "Next", action: finish)
                    .disabled(saving || (!isFirstLaunch && titles.isEmpty))
            }
        }
        .navigationDestination(isPresented: $showingNext) {
            if let then { RoutineSetupView(routine: then, close: leave) }
        }
        .onAppear { focused = entries.first?.id }
        // On a new device the store is empty until iCloud delivers. If habits arrive while
        // nothing has been typed, they are the person's own, and setting up again would
        // duplicate them.
        .onChange(of: model.histories.isEmpty) { _, empty in
            if !empty, !savedAny, !saving, titles.isEmpty { leave() }
        }
    }

    private var footer: String {
        var text = "Enter the \(routine.title.lowercased()) habits you already do. Any number can join today. From tomorrow, the routine takes a new habit once every one of these has bedded in: \(LockInGate.requiredOccurrences) sessions at \(Int(LockInGate.requiredRate * 100))% or better."
        if then != nil {
            text += " Already using Habit Planner on another device? Choose Not now, and your habits will arrive from iCloud."
        }
        return text
    }

    private func example(for id: UUID) -> String {
        let examples = routine == .morning
            ? ["Drink a glass of water", "Stretch", "Make the bed"]
            : ["Lay out tomorrow's clothes", "Read ten pages", "Brush and floss"]
        let index = entries.firstIndex { $0.id == id } ?? 0
        return examples[index % examples.count]
    }

    private func addEntry() {
        let entry = Entry()
        entries.append(entry)
        focused = entry.id
    }

    private func finish() {
        let toAdd = titles
        guard !toAdd.isEmpty else {
            // Nothing for this routine. On first launch, carry on to the next.
            if then != nil { showingNext = true } else { leave() }
            return  // Only reachable on first launch, where an empty routine is allowed.
        }
        saving = true
        Task {
            let added = await model.addStartingSet(toAdd, to: routine)
            saving = false
            savedAny = savedAny || added > 0
            // What was saved moves up into the routine, so trying again adds only the rest.
            let rest = toAdd.dropFirst(added).map { Entry(title: $0) }
            entries = rest.isEmpty ? [Entry()] : rest
            guard rest.isEmpty else { return }
            if then != nil { showingNext = true } else { leave() }
        }
    }
}
