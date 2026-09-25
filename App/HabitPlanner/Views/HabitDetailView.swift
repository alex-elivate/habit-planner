import HabitKit
import HealthKit
import SwiftUI

struct HabitDetailView: View {
    @Environment(AppModel.self) private var model
    let habitID: UUID

    @State private var editing = false
    @State private var linking = false
    @State private var confirmingArchive = false

    var body: some View {
        if let history = model.history(for: habitID) {
            content(history)
        } else {
            ContentUnavailableView("Habit not found", systemImage: "questionmark.circle")
        }
    }

    private func content(_ history: HabitHistory) -> some View {
        let habit = history.habit
        let assessment = LockInGate.assess(history)
        return List {
            Section {
                if let cue = habit.cue { LabeledContent("Cue", value: cue) }
                if let small = habit.twoMinuteVersion { LabeledContent("Two-minute version", value: small) }
                if let identity = habit.identityStatement { LabeledContent("Identity", value: identity) }
                LabeledContent("Schedule", value: habit.schedule.summary)
                LabeledContent("Routine", value: habit.routine.title)
            }

            Section("Progress") {
                LabeledContent("Streak", value: history.streak.caption)
                LabeledContent("Last 7 days",
                               value: ScoreEngine.score(for: [history]).map { "\($0)" } ?? "–")
                VStack(alignment: .leading, spacing: 6) {
                    Text(assessment.isLockedIn ? "Bedded in" : "Bedding in")
                    ProgressView(value: assessment.repetitionProgress)
                    Text(assessment.explanation).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            HealthLinkSection(habitID: habitID, linking: $linking)

            Section {
                switch history.currentState {
                case .active:
                    Button("Pause", systemImage: "pause") {
                        Task { await model.setState(.paused, for: habitID) }
                    }
                    Button("Archive", systemImage: "archivebox", role: .destructive) {
                        confirmingArchive = true
                    }
                case .paused:
                    Button("Resume", systemImage: "play") {
                        Task { await model.setState(.active, for: habitID) }
                    }
                    Button("Archive", systemImage: "archivebox", role: .destructive) {
                        confirmingArchive = true
                    }
                case .archived:
                    Button("Restore", systemImage: "arrow.uturn.backward") {
                        Task { await model.setState(.active, for: habitID) }
                    }
                    .disabled(!model.canRestore(habitID))
                }
            } footer: {
                switch history.currentState {
                case .archived where !model.canRestore(habitID):
                    Text("Restoring works like adding a habit. It can come back once the routine's newest habit beds in.")
                case .archived:
                    Text("Restoring puts it back at the end of the routine's queue for bedding in.")
                default:
                    Text("Paused days are not counted against you. A paused habit that has not bedded in still holds the routine's next slot. Archiving frees it and keeps the history.")
                }
            }
        }
        .navigationTitle(habit.title)
        .toolbar {
            Button("Edit") { editing = true }
        }
        .sheet(isPresented: $editing) {
            NavigationStack { HabitEditorView(mode: .edit(habitID), habit: habit) }
        }
        .sheet(isPresented: $linking) {
            NavigationStack { HealthLinkPicker(habitID: habitID) }
        }
        .confirmationDialog("Archive \(habit.title)?", isPresented: $confirmingArchive, titleVisibility: .visible) {
            Button("Archive", role: .destructive) {
                Task { await model.setState(.archived, for: habitID) }
            }
        } message: {
            Text("Its history stays. You can restore it later.")
        }
    }
}

extension Schedule {
    var summary: String {
        switch self {
        case .daily:
            return "Every day"
        case .daysOfWeek(let days):
            if days == Weekday.weekdays { return "Weekdays" }
            if days == Weekday.weekend { return "Weekends" }
            return Weekday.allCases.filter(days.contains).map { $0.name.prefix(3) }.joined(separator: ", ")
        }
    }
}

private struct HealthLinkSection: View {
    @Environment(AppModel.self) private var model
    @Environment(HealthService.self) private var health
    let habitID: UUID
    @Binding var linking: Bool
    @State private var name: String?

    var body: some View {
        if health.isAvailable {
            Section {
                if let binding = model.bindings[habitID] {
                    LabeledContent("Linked to", value: name ?? "…")
                        .task(id: binding) { name = await health.describe(binding) }
                    Button("Unlink", role: .destructive) {
                        Task { await model.unlink(habitID) }
                    }
                } else {
                    Button("Link to Apple Health", systemImage: "heart.text.square") { linking = true }
                }
            } header: {
                Text("Apple Health")
            } footer: {
                Text("When this habit comes up, the app checks Health and offers to count it if you already did it. What it links to stays on this iPhone and never goes to iCloud.")
            }
        }
    }
}

private struct HealthLinkPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(HealthService.self) private var health
    @Environment(\.dismiss) private var dismiss
    let habitID: UUID

    @State private var medications: [HealthService.Medication]?
    @State private var problem: String?

    var body: some View {
        List {
            Section("Workouts") {
                ForEach(HealthService.workoutChoices, id: \.type.rawValue) { choice in
                    Button(choice.name) { linkWorkout(choice.type) }
                }
            }
            Section {
                if let medications {
                    if medications.isEmpty {
                        Text("No medications shared. Add them in the Health app, then choose them here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(medications) { medication in
                        Button(medication.name) { linkMedication(medication) }
                    }
                } else {
                    Button("Choose medications", action: loadMedications)
                }
            } header: {
                Text("Medications")
            } footer: {
                Text("Counts a dose you log as taken in Health. Health keeps the medication, dose and schedule.")
            }
            if let problem {
                Section { Text(problem).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Link to Health")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
    }

    private func linkWorkout(_ type: HKWorkoutActivityType) {
        Task {
            do {
                try await health.requestWorkoutAccess()
                await model.link(habitID, signal: .workout, externalIdentifier: String(type.rawValue))
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func loadMedications() {
        Task {
            do {
                medications = try await health.requestMedicationAccess()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func linkMedication(_ medication: HealthService.Medication) {
        Task {
            await model.link(habitID, signal: .medication, externalIdentifier: medication.id)
            dismiss()
        }
    }
}
