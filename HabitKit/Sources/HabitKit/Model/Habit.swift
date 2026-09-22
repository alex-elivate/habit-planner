import Foundation

/// A single habit inside a routine.
///
/// Note what is *not* here: no streak count, no `isLockedIn`, no completion tally. Those are
/// folded from the completion log on demand. Storing them would mean an irreversible gate
/// decision resting on mutable state replicated last-writer-wins, which misfires quietly.
public struct Habit: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID

    public var title: String

    /// The anchor this habit is stacked onto: "after I pour my coffee".
    public var cue: String?

    /// The version so small it cannot be refused: "put on my running shoes".
    public var twoMinuteVersion: String?

    /// The identity each completion votes for: "I'm someone who moves every morning".
    public var identityStatement: String?

    public var routine: RoutineSlot

    /// Display position within the routine. Safe to reorder freely, because no identifier
    /// is derived from it.
    public var order: Int

    public var schedule: Schedule

    /// First day this habit could be due. History before it is not counted against you.
    public var startedOn: DayKey

    /// Set by the person, never inferred. Distinct from lock-in, which is always derived.
    public var lifecycle: Lifecycle

    /// The day a pause took effect, if one did.
    ///
    /// Without this, pausing would quietly accrue misses for every day you were away and
    /// wipe out gate progress you had earned. Pausing should cost nothing.
    public var pausedOn: DayKey?

    public enum Lifecycle: String, Hashable, Codable, Sendable {
        case active
        case paused
        case archived
    }

    public init(
        id: UUID = UUID(),
        title: String,
        cue: String? = nil,
        twoMinuteVersion: String? = nil,
        identityStatement: String? = nil,
        routine: RoutineSlot,
        order: Int,
        schedule: Schedule = .daily,
        startedOn: DayKey,
        lifecycle: Lifecycle = .active,
        pausedOn: DayKey? = nil
    ) {
        self.id = id
        self.title = title
        self.cue = cue
        self.twoMinuteVersion = twoMinuteVersion
        self.identityStatement = identityStatement
        self.routine = routine
        self.order = order
        self.schedule = schedule
        self.startedOn = startedOn
        self.lifecycle = lifecycle
        self.pausedOn = pausedOn
    }

    /// Whether the habit was on the hook for `day`, ignoring whether it is active now.
    ///
    /// This is the predicate history is built from, so that archiving or pausing a habit
    /// today does not rewrite what was true last month.
    public func wasScheduled(on day: DayKey) -> Bool {
        guard day >= startedOn else { return false }
        if let pausedOn, day >= pausedOn { return false }
        return schedule.isScheduled(on: day)
    }

    /// Whether this habit should be presented for completion on `day`.
    public func isDue(on day: DayKey) -> Bool {
        lifecycle == .active && wasScheduled(on: day)
    }
}
