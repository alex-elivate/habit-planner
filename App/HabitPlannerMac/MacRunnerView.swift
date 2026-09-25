import HabitKit
import SwiftUI

/// One habit at a time, on the Mac. The same `RoutineRunner` and the same write order as the
/// phone: the completion first, then the run, and the runner steps back if the completion
/// fails. Return marks it done, S skips, and Command-Z goes back.
struct MacRunnerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let routine: RoutineSlot

    @State private var runner: RoutineRunner?
    @State private var total = 0
    @State private var writes: Task<Void, Never>?
    @State private var generation = 0
    /// Habits this runner recorded itself, so its own late writes are not taken for ticks from
    /// elsewhere. See the phone's runner.
    @State private var recordedHere: Set<UUID> = []

    var body: some View {
        VStack(spacing: 20) {
            if let runner {
                if let habitID = runner.currentHabitID, let habit = model.history(for: habitID)?.habit {
                    Text("\(total - runner.remaining.count + 1) of \(total)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let cue = habit.cue { Text(cue).font(.title3).foregroundStyle(.secondary) }
                    Text(habit.title)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("runner.habit")
                    if let small = habit.twoMinuteVersion {
                        Text("Two minutes: \(small)").foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack {
                        Button("Back", systemImage: "arrow.uturn.backward", action: undo)
                            .disabled(runner.passed.isEmpty)
                            .keyboardShortcut("z", modifiers: .command)
                        Spacer()
                        Button("Skip", action: skip)
                            .keyboardShortcut("s", modifiers: [])
                        Button("Done", action: complete)
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                } else {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.tint)
                    Text("\(routine.title) routine finished").font(.title2.weight(.semibold))
                    Text(summary(runner)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                ProgressView()
            }
        }
        .padding(28)
        .frame(width: 460, height: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
        }
        .task { await plan() }
        .onChange(of: model.histories) { followOutsideTicks() }
    }

    private func summary(_ runner: RoutineRunner) -> String {
        let done = runner.passed.filter { if case .completed = $0.outcome { return true }; return false }.count
        let skipped = runner.passed.count - done
        return skipped == 0 ? "\(done) done." : "\(done) done, \(skipped) skipped."
    }

    // MARK: - Transitions

    /// Planned from a fresh fold, as on the phone, so a Mac left open overnight cannot write
    /// this morning's completions to yesterday.
    private func plan() async {
        guard runner == nil else { return }
        await model.reload()
        guard runner == nil else { return }
        let planned = RoutineRunner(routine: routine, histories: model.histories,
                                    resuming: model.runsToday[routine], at: .now, in: model.timeZone)
        runner = planned
        total = planned.remaining.count
        persist(nil)
    }

    private func followOutsideTicks() {
        guard let current = runner?.currentHabitID, !recordedHere.contains(current),
              model.history(for: current)?.isCompletedToday == true else { return }
        generation += 1
        runner = RoutineRunner(routine: routine, histories: model.histories,
                               resuming: model.runsToday[routine], at: .now, in: model.timeZone)
    }

    private func complete() {
        let before = runner
        if let current = runner?.currentHabitID { recordedHere.insert(current) }
        let event = runner?.complete(at: .now)
        persist(event, rollingBackTo: before)
    }

    private func skip() {
        runner?.skip(at: .now)
        persist(nil)
    }

    private func undo() {
        let before = runner
        let retraction = runner?.undo(at: .now)
        persist(retraction, rollingBackTo: before)
    }

    private func persist(_ event: CompletionEvent?, rollingBackTo before: RoutineRunner? = nil) {
        guard let run = runner?.run, runner?.hasSteps == true else { return }
        let previous = writes
        let expected = generation
        writes = Task {
            await previous?.value
            guard generation == expected else { return }
            if let event, await model.record(event) == false {
                generation += 1
                if let before { runner = before }
                return
            }
            await model.save(run)
        }
    }
}
