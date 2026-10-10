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

/// What a swipe in the list does to one habit.
public enum ListAction: Hashable, Sendable {
    /// Done. `occurredAt` is set when Health proposed it and the person confirmed.
    case complete(occurredAt: Date? = nil)
    /// Done because Health shows it, without the person asking. Refused if the day already
    /// carries any assertion for the habit, a retraction included, so a habit somebody marked
    /// not done, or whose count from Health they undid, stays as they left it.
    case propose(occurredAt: Date)
    case skip
    /// Undoes whichever of the two was done: retracts a completion and reopens its step.
    case reopen
}

extension HabitStoreActor {

    /// Applies a swipe from the list to `habitID`, on `day`. Returns whether anything changed.
    ///
    /// `day` is the day the list was folded for, as for the old checkbox. In the minutes
    /// between midnight and the next reload it differs from the clock's day, and a swipe must
    /// land on the day the row shows.
    ///
    /// Plans the same `RoutineRunner` the widget and Siri use, so a habit done or skipped here
    /// is passed on today's run and the next habit is the same everywhere. A skipped habit can
    /// still be done, which records the completion and leaves its step as it was.
    ///
    /// Writes the completion before the run, as `completeCurrentStep` does.
    @discardableResult
    public func apply(
        _ action: ListAction,
        to habitID: UUID,
        on day: DayKey,
        at instant: Date,
        timeZone: TimeZone
    ) throws -> Bool {
        let histories = try loadHistories(today: day).values
        guard let history = histories.first(where: { $0.habit.id == habitID }) else { return false }
        let routine = history.habit.routine
        let existing = try loadRoutineRuns().values.first { $0.routine == routine && $0.dayKey == day }
        // Opened on the list's day rather than the clock's, for the reason above.
        let run = existing ?? RoutineRun(routine: routine, dayKey: day, startedAt: instant,
                                         timeZoneIdentifier: timeZone.identifier)
        var runner = RoutineRunner(routine: routine, histories: histories, resuming: run,
                                   at: instant, in: timeZone)

        switch action {
        case .propose(let occurredAt):
            guard history.isDueToday, !history.isCompletedToday,
                  try loadCompletionEvents(for: habitID).values.allSatisfy({ $0.dayKey != day })
            else { return false }
            return try complete(habitID, at: occurredAt, source: .automatic, runner: &runner,
                                day: day, instant: instant, timeZone: timeZone)

        case .complete(let occurredAt):
            guard history.isDueToday, !history.isCompletedToday else { return false }
            return try complete(habitID, at: occurredAt, source: occurredAt == nil ? .manual : .automatic,
                                runner: &runner, day: day, instant: instant, timeZone: timeZone)

        case .skip:
            guard runner.remaining.contains(habitID) else { return false }
            runner.skip(habitID, at: instant)
            try upsert(runner.run)
            return true

        case .reopen:
            var changed = false
            if history.isCompletedToday {
                try retract(habitID: habitID, dayKey: day, at: instant,
                            timeZoneIdentifier: timeZone.identifier)
                changed = true
            }
            // Only a stored run can have a step to reopen.
            if var stored = existing, stored.reopen(habitID, at: instant) {
                try upsert(stored)
                changed = true
            }
            return changed
        }
    }

    /// Records the completion, then passes its step on the run if it was still to come.
    private func complete(
        _ habitID: UUID, at occurredAt: Date?, source: CompletionSource,
        runner: inout RoutineRunner, day: DayKey, instant: Date, timeZone: TimeZone
    ) throws -> Bool {
        if let event = runner.complete(habitID, at: instant, occurredAt: occurredAt, source: source) {
            try record(event)
            try upsert(runner.run)
        } else {
            // Skipped earlier today. The step stays passed, and the habit is now done.
            try record(CompletionEvent(habitID: habitID, dayKey: day, source: source,
                                       occurredAt: occurredAt ?? instant, recordedAt: instant,
                                       timeZoneIdentifier: timeZone.identifier))
        }
        return true
    }
}
