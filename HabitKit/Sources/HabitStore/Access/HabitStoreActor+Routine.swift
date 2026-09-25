import Foundation
import HabitKit

/// What happened when the current step of a routine was marked done from outside the runner.
public enum StepOutcome: Hashable, Sendable {
    /// `done` was recorded. `next` is the habit now on offer, `nil` if the routine is finished.
    case completed(done: String, next: String?, remaining: Int)
    /// Nothing was left to do today.
    case nothingLeft
    /// The routine has no habit due today at all.
    case nothingDue
}

extension HabitStoreActor {

    /// Everything a widget or Siri shows, folded for `instant`.
    ///
    /// The one way to build a `Glance` from the store, so the widget's timeline and an intent's
    /// answer cannot fold differently.
    public func glance(at instant: Date, in timeZone: TimeZone) throws -> Glance {
        try glances(at: [instant], in: timeZone)[0]
    }

    /// One glance per instant, for a widget timeline.
    ///
    /// Runs and plans are read once, and histories are folded once per day rather than once per
    /// instant, since a morning timeline holds two entries for the same day.
    public func glances(at instants: [Date], in timeZone: TimeZone) throws -> [Glance] {
        let runs = try loadRoutineRuns().values
        let planned = try loadPlannedHabits().values.resolved()
        var folds: [DayKey: LoadResult<HabitHistory>] = [:]
        return try instants.map { instant in
            let day = DayKey(instant, in: timeZone)
            let histories: LoadResult<HabitHistory>
            if let fold = folds[day] {
                histories = fold
            } else {
                histories = try loadHistories(today: day)
                folds[day] = histories
            }
            return Glance(
                histories: histories.values,
                runs: Dictionary(runs.filter { $0.dayKey == day }.map { ($0.routine, $0) },
                                 uniquingKeysWith: { first, _ in first }),
                planned: planned,
                gateHasUnreadableInput: histories.skipped.contains(where: \.couldOpenGate),
                at: instant,
                in: timeZone
            )
        }
    }

    /// Marks done the habit the runner would offer now, exactly as tapping Done in it would.
    ///
    /// For Siri, Shortcuts and the widget's button. It plans the same `RoutineRunner` from the
    /// same fold the on-screen runner plans from, resuming today's run, so it can only ever tick
    /// the habit next in sequence. Skipped steps stay skipped and are not offered again.
    ///
    /// Writes the completion before the run, the order the runner view uses: if the completion
    /// fails, nothing records the step as passed, and the habit is offered again next time.
    public func completeCurrentStep(
        in routine: RoutineSlot,
        at instant: Date,
        timeZone: TimeZone
    ) throws -> StepOutcome {
        let day = DayKey(instant, in: timeZone)
        let histories = try loadHistories(today: day).values
        let existing = try loadRoutineRuns().values.first { $0.routine == routine && $0.dayKey == day }

        var runner = RoutineRunner(routine: routine, histories: histories, resuming: existing,
                                   at: instant, in: timeZone)
        let titles = Dictionary(histories.map { ($0.habit.id, $0.habit.title) }, uniquingKeysWith: { first, _ in first })

        guard let doneID = runner.currentHabitID, let event = runner.complete(at: instant) else {
            let anyDue = histories.contains { $0.habit.routine == routine && $0.isDueToday }
            return anyDue ? .nothingLeft : .nothingDue
        }
        try record(event)
        try upsert(runner.run)

        return .completed(
            done: titles[doneID] ?? "",
            next: runner.currentHabitID.flatMap { titles[$0] },
            remaining: runner.remaining.count
        )
    }
}
