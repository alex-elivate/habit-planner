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

    /// When the person moved past it. `nil` while it is still on screen, and on a routine
    /// abandoned midway, which is a normal and expected shape.
    public var endedAt: Date?

    public init(habitID: UUID, position: Int, startedAt: Date? = nil, endedAt: Date? = nil) {
        self.habitID = habitID
        self.position = position
        self.startedAt = startedAt
        self.endedAt = endedAt
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

    /// Wall-clock length of the whole run, or `nil` if it never finished.
    public var duration: TimeInterval? {
        guard let startedAt, let endedAt, endedAt >= startedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}
