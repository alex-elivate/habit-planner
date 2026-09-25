import HabitKit
import SwiftUI

/// One habit at a time, on the wrist. The same `RoutineRunner` as the phone, so the order,
/// the resume point and the day a completion lands on are decided by the same code.
struct WatchRunnerView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let routine: RoutineSlot

    @State private var runner: RoutineRunner?
    @State private var total = 0
    /// Writes are chained so a fast double tap cannot land a run update before its completion.
    @State private var writes: Task<Void, Never>?
    /// Bumped when a write fails, so writes queued after it are dropped with the state they
    /// were made from.
    @State private var generation = 0

    var body: some View {
        NavigationStack {
            Group {
                if let runner {
                    if let habitID = runner.currentHabitID, let history = model.history(for: habitID) {
                        StepView(history: history,
                                 position: total - runner.remaining.count + 1,
                                 total: total,
                                 done: complete,
                                 skip: skip,
                                 canGoBack: !runner.passed.isEmpty,
                                 back: undo)
                            .id(habitID)
                    } else {
                        FinishedView(routine: routine, passed: runner.passed, close: { dismiss() })
                    }
                } else {
                    ProgressView()
                }
            }
            // No Close of its own: a full-screen cover on watchOS already carries one, and a
            // second showed up beside it. Back lives in the step rather than the toolbar,
            // because watchOS never rendered a primary-action toolbar item here at all.
        }
        .sensoryFeedback(.success, trigger: passedCount) { old, new in new > old }
        .task { await plan() }
    }

    private var passedCount: Int { runner?.passed.count ?? 0 }

    // MARK: - Transitions

    /// Plans from a fresh fold. A reminder can open this after the app sat suspended overnight,
    /// and planning from yesterday's fold would write this morning to the day before.
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

    private func complete() {
        let before = runner
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

    /// Writes the assertion, then the run. If the assertion does not reach the store the run
    /// is not written either and the runner steps back, so a step is never saved as passed
    /// with no completion behind it.
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

private struct StepView: View {
    let history: HabitHistory
    let position: Int
    let total: Int
    let done: () -> Void
    let skip: () -> Void
    /// False on the first step of the session, where there is nothing to go back to.
    let canGoBack: Bool
    let back: () -> Void

    private var habit: Habit { history.habit }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("\(position) of \(total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let cue = habit.cue {
                    Text(cue).font(.footnote).foregroundStyle(.secondary)
                }
                Text(habit.title)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .accessibilityIdentifier("runner.habit")
                    .accessibilityAddTraits(.isHeader)
                if let small = habit.twoMinuteVersion {
                    Label("Start with: \(small)", systemImage: "timer")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                // The second miss is where habits die, so the one state worth interrupting for.
                if history.streak.isAtRisk {
                    Label("Missed last time. Don't miss twice.", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                Button(action: done) {
                    Text("Done").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)

                Button("Skip", action: skip)
                    .buttonStyle(.bordered)

                if canGoBack {
                    Button("Back", systemImage: "arrow.uturn.backward", action: back)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            }
            .multilineTextAlignment(.center)
        }
    }
}

private struct FinishedView: View {
    let routine: RoutineSlot
    let passed: [(habitID: UUID, outcome: RoutineRunner.Outcome)]
    let close: () -> Void

    var body: some View {
        let skipped = passed.filter { $0.outcome == .skipped }.count
        let done = passed.count - skipped
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("\(routine.title) done")
                    .font(.system(.headline, design: .rounded))
                if !passed.isEmpty {
                    Text(skipped == 0 ? "\(done) done" : "\(done) done, \(skipped) skipped")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                // Not "Close", which the cover's own close button is already called.
                Button("Finish", action: close)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
    }
}
