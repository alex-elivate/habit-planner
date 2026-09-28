import Foundation

/// One habit's turn inside a routine, with the clock on both ends.
///
/// A completion carries a single instant, which is enough to say a habit was done and not
/// enough for anything else. A walk has a duration. The gap between finishing one step and
/// starting the next is a real signal about whether a routine is actually flowing. Neither
/// question is answerable from a completion instant, and neither is reconstructable later,
/// so the clock is read at the time even though nothing scores it yet.
///
/// Nothing scores it yet on purpose. Rewarding a small gap would put a stopwatch on health
/// behaviours and fight the forgiving design everywhere else in this app. The timestamps are
/// captured so the option stays open, not because a decision has been made.
public struct RoutineStep: Identifiable, Hashable, Codable, Sendable {
    /// A habit appears at most once in a run, so it is the key within one.
    public var id: UUID { habitID }

    public let habitID: UUID

    /// Where this step fell in the sequence actually presented.
    ///
    /// Not `Habit.order`, and not an identifier. This records the order the person was walked
    /// through on the day, which is worth keeping because reordering the routine later must
    /// not rewrite what happened. Nothing keys on it.
    public var position: Int

    /// When the step was presented. `nil` until it is reached.
    public var startedAt: Date?

    /// When the person last moved past it. `nil` until they do, and on a routine abandoned
    /// midway, which is a normal and expected shape. A reopened step keeps its old end, so
    /// read `isPassed` to know whether it is passed now.
    public var endedAt: Date?

    /// When the person last put the step back: Unskip or Not done in the list, or Back in the
    /// watch's runner. `nil` if it never was.
    ///
    /// A reopen is its own clock rather than a cleared `endedAt`, because every copy of a run
    /// merges by keeping the latest end. Clearing it was undone by the next stale copy to
    /// arrive, from the watch or from another device through iCloud. With both clocks kept at
    /// their latest, whichever happened last wins on every device. See `isPassed`.
    public var reopenedAt: Date?

    public init(habitID: UUID, position: Int, startedAt: Date? = nil, endedAt: Date? = nil,
                reopenedAt: Date? = nil) {
        self.habitID = habitID
        self.position = position
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.reopenedAt = reopenedAt
    }

    /// Whether the person has moved past this step: it ended, and not before it was last put
    /// back. The one reading of the two clocks. Nothing else compares them.
    ///
    /// Clocks from two devices are compared as they are. If one runs minutes fast, a pass it
    /// recorded can outrank a reopen that really came later. The clamps in `pass(at:)` and
    /// `reopen(at:)` order only clocks this device has already seen. The 1 ms step they add
    /// survives CloudKit's millisecond precision.
    public var isPassed: Bool {
        guard let endedAt else { return false }
        guard let reopenedAt else { return true }
        return endedAt > reopenedAt
    }

    /// Ends the step at `instant`, or just after its last reopen if the clock says earlier.
    /// Another device's clock can run ahead, and a pass must never read as older than the
    /// reopen it follows.
    mutating func pass(at instant: Date) {
        if startedAt == nil { startedAt = instant }
        endedAt = reopenedAt.map { max(instant, $0.addingTimeInterval(0.001)) } ?? instant
    }

    /// Puts the step back at `instant`, or at its end if the clock says earlier, for the same
    /// reason as `pass(at:)`.
    mutating func reopen(at instant: Date) {
        reopenedAt = endedAt.map { max(instant, $0) } ?? instant
    }

    /// Two copies of the same step combined: the earliest start, the latest end, the latest
    /// reopen and the lowest position. Commutative, associative and idempotent, so copies
    /// arriving in any order settle on one answer.
    public func merged(with other: RoutineStep) -> RoutineStep {
        precondition(habitID == other.habitID, "Merging a step for another habit")
        return RoutineStep(
            habitID: habitID,
            position: Swift.min(position, other.position),
            startedAt: earliest(startedAt, other.startedAt),
            endedAt: latest(endedAt, other.endedAt),
            reopenedAt: latest(reopenedAt, other.reopenedAt)
        )
    }

    /// How long the step took, or `nil` if it never finished.
    public var duration: TimeInterval? {
        guard let startedAt, let endedAt, endedAt >= startedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}

/// A single pass through one routine on one day.
///
/// Identity is content-addressed from `(routine, dayKey)`, like the event logs, so the same
/// morning arriving from two devices collapses to one record rather than double-counting.
///
/// Unlike `CompletionEvent` and `LifecycleEvent`, this is **not** an immutable assertion.
/// A run is opened when the routine starts and is written to as each step is reached, so
/// equality is structural rather than delegated to `id`. Two runs of the same morning that
/// disagree about what happened are genuinely different records, and a fold that treated
/// them as equal would silently keep whichever it saw first.
public struct RoutineRun: Identifiable, Hashable, Codable, Sendable {
    /// One run per routine per day. The store dedupes on this.
    public var id: String { "\(routine.rawValue)|\(dayKey.rawValue)" }

    public let routine: RoutineSlot

    /// The civil day this run belongs to, resolved in `timeZoneIdentifier` when it started.
    ///
    /// Resolved once and stored, like every other day in this app. An evening routine that
    /// runs past midnight still belongs to the day it began.
    public let dayKey: DayKey

    public var startedAt: Date?
    public var endedAt: Date?

    public let timeZoneIdentifier: String

    /// The steps of this run. Not guaranteed sorted; read `orderedSteps`.
    public var steps: [RoutineStep]

    public init(
        routine: RoutineSlot,
        dayKey: DayKey,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        timeZoneIdentifier: String,
        steps: [RoutineStep] = []
    ) {
        self.routine = routine
        self.dayKey = dayKey
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.steps = steps
    }

    /// Opens a run now, resolving the civil day in `timeZone`.
    public init(routine: RoutineSlot, startingAt instant: Date, in timeZone: TimeZone) {
        self.init(
            routine: routine,
            dayKey: DayKey(instant, in: timeZone),
            startedAt: instant,
            timeZoneIdentifier: timeZone.identifier
        )
    }

    /// The steps in the sequence they were presented.
    ///
    /// Ties break on the habit identifier rather than on array position, so a run assembled
    /// from an unordered store fetch reads the same every time.
    public var orderedSteps: [RoutineStep] {
        steps.sorted {
            $0.position == $1.position
                ? $0.habitID.uuidString < $1.habitID.uuidString
                : $0.position < $1.position
        }
    }

    /// Puts a passed step back, so a runner planned from this run offers the habit again.
    ///
    /// The list's Unskip, half of its Not done, and the watch runner's Back. Returns whether
    /// anything changed. The run is reopened too, since it now has a step to come back to.
    /// Carried across devices by `RoutineStep.reopenedAt`.
    @discardableResult
    public mutating func reopen(_ habitID: UUID, at instant: Date) -> Bool {
        guard let index = steps.firstIndex(where: { $0.habitID == habitID }),
              steps[index].isPassed else { return false }
        steps[index].reopen(at: instant)
        endedAt = nil
        return true
    }

    /// Wall-clock length of the whole run, or `nil` if it never finished.
    public var duration: TimeInterval? {
        guard let startedAt, let endedAt, endedAt >= startedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}

func earliest(_ lhs: Date?, _ rhs: Date?) -> Date? {
    guard let lhs else { return rhs }
    guard let rhs else { return lhs }
    return Swift.min(lhs, rhs)
}

func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
    guard let lhs else { return rhs }
    guard let rhs else { return lhs }
    return Swift.max(lhs, rhs)
}
