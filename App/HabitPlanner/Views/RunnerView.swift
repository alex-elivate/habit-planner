import HabitKit
import SwiftUI

/// One habit at a time. The only ways forward are Done and Skip.
struct RunnerView: View {
    @Environment(AppModel.self) private var model
    @Environment(HealthService.self) private var health
    @Environment(\.dismiss) private var dismiss

    let routine: RoutineSlot

    @State private var runner: RoutineRunner?
    @State private var total = 0
    /// What Health reported, and for which habit. Keyed so an answer that arrives after the
    /// person has moved on can never be offered against the next habit.
    @State private var healthOffer: (habitID: UUID, at: Date)?
    /// Writes are chained so a fast double tap cannot land a run update before its completion.
    @State private var writes: Task<Void, Never>?
    /// Bumped when a write fails, so writes queued after it are dropped with the state they
    /// were made from.
    @State private var generation = 0
    /// Habits this runner recorded itself. Its own writes land after it has moved on, and after
    /// Back it can be showing a habit whose completion is still on its way to the store. That
    /// arrival is not a tick from elsewhere and must not be followed.
    @State private var recordedHere: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Group {
                if let runner {
                    if let habitID = runner.currentHabitID, let history = model.history(for: habitID) {
                        let offer = healthOffer?.habitID == habitID ? healthOffer?.at : nil
                        StepView(habit: history.habit, healthOffer: offer,
                                 bindingName: bindingName(for: habitID),
                                 done: { complete(occurredAt: nil) },
                                 countHealth: { complete(occurredAt: offer) },
                                 skip: skip)
                            .id(habitID)
                            .transition(.push(from: .trailing))
                            .task(id: habitID) { await checkHealth(habitID) }
                    } else {
                        FinishedView(routine: routine, passed: runner.passed, close: { dismiss() })
                            .transition(.opacity)
                    }
                } else {
                    ProgressView()
                }
            }
            .animation(.snappy, value: runner?.currentHabitID)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // The finished screen has its own Close, and two would be one too many.
                    if runner?.isFinished != true {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                }
                ToolbarItem(placement: .principal) {
                    if let runner, !runner.isFinished {
                        Text("\(total - runner.remaining.count + 1) of \(total)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let runner, !runner.passed.isEmpty {
                        Button("Back", systemImage: "arrow.uturn.backward", action: undo)
                    }
                }
            }
        }
        .sensoryFeedback(.success, trigger: runner?.passed.count ?? 0) { old, new in new > old }
        .task { await plan() }
        .onChange(of: model.histories) { followOutsideTicks() }
    }

    // MARK: - Transitions

    /// Plans from a fresh fold, never from whatever the model held last.
    ///
    /// A reminder usually opens this after the app sat suspended, so the model can still hold
    /// yesterday: yesterday's run, folded for yesterday. Planning from that resumed yesterday's
    /// run and wrote this morning's completions to the day before. On a cold launch the model
    /// is empty and the routine read as already done. Reloading first rules out both, and a
    /// reload keeps only today's runs.
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

    /// Moves on when the habit on screen is ticked somewhere else.
    ///
    /// Siri, the widget's Done button, or the list on another device can each tick the habit
    /// this runner is showing. The store is right and the runner is stale, so it is planned again
    /// from the store, which resumes past the ticked step. Steps passed earlier in this session
    /// can no longer be undone from here, only from the list. Queued writes made from the stale
    /// runner are dropped.
    private func followOutsideTicks() {
        guard let current = runner?.currentHabitID, !recordedHere.contains(current),
              model.history(for: current)?.isCompletedToday == true else { return }
        generation += 1
        runner = RoutineRunner(routine: routine, histories: model.histories,
                               resuming: model.runsToday[routine], at: .now, in: model.timeZone)
    }

    private func complete(occurredAt: Date?) {
        let before = runner
        if let current = runner?.currentHabitID { recordedHere.insert(current) }
        let source: CompletionSource = occurredAt == nil ? .manual : .automatic
        let event = runner?.complete(at: .now, occurredAt: occurredAt, source: source)
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

    /// Writes the assertion, then the run, in that order.
    ///
    /// If the assertion does not reach the store the run is not written either, and the
    /// runner goes back to where it was. Otherwise the step would be saved as passed with no
    /// completion behind it, never offered again, and the habit quietly skipped.
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

    // MARK: - Health

    private func bindingName(for habitID: UUID) -> String? {
        guard let binding = model.bindings[habitID] else { return nil }
        switch binding.signal {
        case .workout: return HealthService.workoutName(for: binding.externalIdentifier).lowercased()
        case .medication: return "dose"
        }
    }

    /// Asks Health whether this step already happened today, while the person is looking.
    ///
    /// A foreground query answers at once, unlike background delivery. An offer is only ever
    /// an offer: the person confirms it, and an empty answer offers nothing.
    private func checkHealth(_ habitID: UUID) async {
        guard let binding = model.bindings[habitID], let day = runner?.run.dayKey else { return }
        let interval = DateInterval(start: day.start(in: model.timeZone), end: .now)
        let found = try? await health.signalInstants(for: binding, in: interval).first
        guard !Task.isCancelled, runner?.currentHabitID == habitID, let found else { return }
        healthOffer = (habitID, found)
    }
}

private struct StepView: View {
    let habit: Habit
    let healthOffer: Date?
    let bindingName: String?
    let done: () -> Void
    let countHealth: () -> Void
    let skip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                if let cue = habit.cue {
                    Text(cue).font(.title3).foregroundStyle(.secondary)
                }
                Text(habit.title)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .accessibilityIdentifier("runner.habit")
                    .accessibilityAddTraits(.isHeader)
                if let small = habit.twoMinuteVersion {
                    Label("Start with: \(small)", systemImage: "timer")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            Spacer()

            if let identity = habit.identityStatement {
                Text(identity)
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }

            VStack(spacing: 12) {
                if let healthOffer {
                    Button(action: countHealth) {
                        Label("Health shows a \(bindingName ?? "match") at \(healthOffer.formatted(date: .omitted, time: .shortened)). Count it",
                              systemImage: "heart.text.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.pink)
                }
                Button(action: done) {
                    Text("Done").font(.title3.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                Button("Skip", action: skip)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
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
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: passed.count)
            Text("\(routine.title) routine done")
                .font(.system(.title, design: .rounded, weight: .bold))
            if !passed.isEmpty {
                Text(skipped == 0 ? "\(done) done" : "\(done) done, \(skipped) skipped")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: close) {
                Text("Close").frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
    }
}
