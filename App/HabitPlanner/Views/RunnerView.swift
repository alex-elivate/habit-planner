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
    @State private var healthOffer: Date?
    /// Writes are chained so a fast double tap cannot land a run update before its completion.
    @State private var writes: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if let runner {
                    if let habitID = runner.currentHabitID, let history = model.history(for: habitID) {
                        StepView(habit: history.habit, healthOffer: healthOffer,
                                 bindingName: bindingName(for: habitID),
                                 done: { complete(occurredAt: nil) },
                                 countHealth: { complete(occurredAt: healthOffer) },
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
        .onAppear(perform: plan)
    }

    // MARK: - Transitions

    private func plan() {
        guard runner == nil else { return }
        let planned = RoutineRunner(routine: routine, histories: model.histories,
                                    resuming: model.runsToday[routine], at: .now, in: model.timeZone)
        runner = planned
        total = planned.remaining.count
        persist(nil)
    }

    private func complete(occurredAt: Date?) {
        let source: CompletionSource = occurredAt == nil ? .manual : .automatic
        let event = runner?.complete(at: .now, occurredAt: occurredAt, source: source)
        persist(event)
    }

    private func skip() {
        runner?.skip(at: .now)
        persist(nil)
    }

    private func undo() {
        let retraction = runner?.undo(at: .now)
        persist(retraction)
    }

    private func persist(_ event: CompletionEvent?) {
        guard let run = runner?.run, runner?.hasSteps == true else { return }
        let previous = writes
        writes = Task {
            await previous?.value
            if let event { await model.record(event) }
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
        healthOffer = nil
        guard let binding = model.bindings[habitID], let day = runner?.run.dayKey else { return }
        let interval = DateInterval(start: day.start(in: model.timeZone), end: .now)
        healthOffer = try? await health.signalInstants(for: binding, in: interval).first
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
