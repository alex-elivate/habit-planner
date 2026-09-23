import Foundation

/// Walks the person through one routine, one habit at a time.
///
/// This is the product. A checklist lets you cherry-pick, and cherry-picking works against the
/// point of a routine, where the sequence is what makes the behaviour automatic. So the runner
/// only ever offers one habit, and the only ways forward are to do it or to skip it.
///
/// ### What it writes, and what it does not
///
/// Doing a habit returns a `CompletionEvent` for the caller to record. Skipping returns nothing,
/// because a skip is not an assertion about the habit. It is the absence of one, and the fold
/// already reads an absent completion on a settled day as a miss. Recording a skip as its own
/// status would be a second way to say "not done" that every consumer would have to agree with.
///
/// Whether a passed step was done or skipped is therefore **not stored on the run**. It is
/// answerable from the completion log, and a second copy of it on the step would be one more
/// thing that could disagree after a correction.
///
/// ### Which day it belongs to
///
/// Every completion lands on the run's `dayKey`, not on the day the tap happened. An evening
/// routine that runs past midnight still belongs to the day it began, which is the rule
/// `RoutineRun` already states.
public struct RoutineRunner: Sendable {
    /// How a step was left.
    public enum Outcome: Hashable, Sendable {
        case completed(CompletionEvent)
        case skipped
    }

    /// The run being written. Persist it after every transition.
    public private(set) var run: RoutineRun

    /// Habits not yet passed, in the order they will be offered. The first is on screen.
    public private(set) var remaining: [UUID]

    /// Steps passed in this session, most recent last. Only these can be undone.
    ///
    /// Held in memory rather than read back from the run, because the run does not know which
    /// steps were done and which skipped. See the type's documentation.
    public private(set) var passed: [(habitID: UUID, outcome: Outcome)] = []

    private let timeZone: TimeZone

    /// Plans a run of `routine`.
    ///
    /// `histories` must be folded for the run's day: today for a fresh run, or `existing.dayKey`
    /// when resuming. The runner reads `isDueToday` and `isCompletedToday` from them.
    ///
    /// Only habits that are due, active and not yet done are offered. A habit already ticked
    /// from the list earlier in the day is not offered again, and neither is one already passed
    /// in `existing`, whether it was done or skipped. Resuming picks up where the person left.
    public init(
        routine: RoutineSlot,
        histories: some Sequence<HabitHistory>,
        resuming existing: RoutineRun? = nil,
        at instant: Date,
        in timeZone: TimeZone
    ) {
        let run = existing ?? RoutineRun(routine: routine, startingAt: instant, in: timeZone)
        precondition(run.routine == routine, "Resuming a \(run.routine) run as \(routine)")

        let alreadyPassed = Set(run.steps.lazy.filter { $0.endedAt != nil }.map(\.habitID))
        let due = histories.filter { history in
            history.habit.routine == routine
                && history.isDueToday
                && !history.isCompletedToday
                && !alreadyPassed.contains(history.habit.id)
        }
        assert(due.allSatisfy { $0.today == run.dayKey }, "Histories folded for another day")

        self.run = run
        self.timeZone = timeZone
        // Sequence order, with the identifier breaking ties so two habits sharing a position
        // come out the same way on every launch and every device.
        let habits: [Habit] = due.map(\.habit).sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        self.remaining = habits.map(\.id)

        if remaining.isEmpty {
            // Nothing left to do. A resumed run that was never closed is closed now.
            if self.run.startedAt != nil, self.run.endedAt == nil { self.run.endedAt = instant }
        } else {
            self.run.endedAt = nil
            present(at: instant)
        }
    }

    /// The habit on screen, or `nil` once the run is over.
    public var currentHabitID: UUID? { remaining.first }

    public var isFinished: Bool { remaining.isEmpty }

    /// Whether this runner had anything to offer when it was planned.
    ///
    /// A routine with nothing due should not leave a run behind, since an empty run on the day
    /// would read as "started the routine" when nothing happened.
    public var hasSteps: Bool { !run.steps.isEmpty }

    /// Marks the current habit done and moves on.
    ///
    /// `occurredAt` differs from `instant` only when an outside signal proposed the completion
    /// and the person confirmed it: the walk happened at 7:40, the tap happens now. Returns the
    /// event to record, or `nil` if the run is already over.
    public mutating func complete(
        at instant: Date,
        occurredAt: Date? = nil,
        source: CompletionSource = .manual
    ) -> CompletionEvent? {
        guard let habitID = currentHabitID else { return nil }
        let event = CompletionEvent(
            habitID: habitID,
            dayKey: run.dayKey,
            source: source,
            occurredAt: occurredAt ?? instant,
            recordedAt: instant,
            timeZoneIdentifier: timeZone.identifier
        )
        advance(outcome: .completed(event), at: instant)
        return event
    }

    /// Moves past the current habit without doing it.
    ///
    /// Nothing is written about the habit. Once the day settles it reads as a miss, which is
    /// what a skip is. Until then it is only unfinished, and the person can still tick it from
    /// the list.
    public mutating func skip(at instant: Date) {
        guard currentHabitID != nil else { return }
        advance(outcome: .skipped, at: instant)
    }

    /// Steps back to the habit just passed.
    ///
    /// If it had been done, returns the retraction to record. A mis-tap in a flow that shows one
    /// thing at a time is a certainty rather than an edge case, and a completion you cannot take
    /// back is one you cannot trust.
    ///
    /// Only steps passed in this session can be undone here. Anything older is corrected from
    /// the list, which works on the completion log directly.
    public mutating func undo(at instant: Date) -> CompletionEvent? {
        guard let last = passed.popLast() else { return nil }

        remaining.insert(last.habitID, at: 0)
        run.endedAt = nil
        if let index = run.steps.firstIndex(where: { $0.habitID == last.habitID }) {
            run.steps[index].endedAt = nil
        }

        guard case .completed(let event) = last.outcome else { return nil }
        return event.retracted(at: instant)
    }

    // MARK: - Transitions

    private mutating func advance(outcome: Outcome, at instant: Date) {
        guard let habitID = remaining.first else { return }
        if let index = run.steps.firstIndex(where: { $0.habitID == habitID }) {
            run.steps[index].endedAt = instant
        }
        remaining.removeFirst()
        passed.append((habitID, outcome))

        if remaining.isEmpty {
            run.endedAt = instant
        } else {
            present(at: instant)
        }
    }

    /// Puts the first remaining habit on screen, adding its step if this run has not seen it.
    ///
    /// A step that was already presented keeps its original `startedAt`. Rewriting it on resume
    /// would change what the record says happened, and nothing scores the gap either way.
    private mutating func present(at instant: Date) {
        guard let habitID = remaining.first else { return }
        if let index = run.steps.firstIndex(where: { $0.habitID == habitID }) {
            if run.steps[index].startedAt == nil { run.steps[index].startedAt = instant }
            return
        }
        let position = (run.steps.map(\.position).max() ?? -1) + 1
        run.steps.append(RoutineStep(habitID: habitID, position: position, startedAt: instant))
    }
}
