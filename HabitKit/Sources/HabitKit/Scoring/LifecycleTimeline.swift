import Foundation

/// A habit's lifecycle log folded into a question you can ask about any single day.
public struct LifecycleTimeline: Hashable, Sendable {
    public struct Transition: Hashable, Sendable {
        public let day: DayKey
        public let state: LifecycleEvent.State
    }

    /// Whose lifecycle this is. Events belonging to anyone else are discarded.
    public let habitID: UUID

    public let startedOn: DayKey

    /// Ascending by day, one per day, with consecutive repeats of the same state removed.
    public let transitions: [Transition]

    /// Folds one habit's lifecycle log.
    ///
    /// `habitID` is required rather than assumed, and the filtering it drives is the whole
    /// reason it is a parameter. `events` is routinely the entire log for every habit,
    /// because that is what a single store fetch returns, and an earlier version took it on
    /// trust. One habit being paused then paused every habit in the app: its neighbours read
    /// as `paused`, and their settled history collapsed to the days since that unrelated
    /// pause, so every score and every gate assessment was computed from a handful of days
    /// instead of months. Nothing crashed and nothing logged.
    ///
    /// Completions never had this problem, because `completedDays(for:)` has always filtered.
    /// The asymmetry was the bug.
    public init(habitID: UUID, startedOn: DayKey, events: some Sequence<LifecycleEvent>) {
        self.habitID = habitID
        self.startedOn = startedOn

        var collapsed: [Transition] = []
        for event in Array(events).deduplicated()
        where event.habitID == habitID && event.dayKey >= startedOn {
            if collapsed.last?.state == event.state { continue }
            collapsed.append(Transition(day: event.dayKey, state: event.state))
        }
        self.transitions = collapsed
    }

    /// The state in force on `day`. A habit is active until something says otherwise.
    public func state(on day: DayKey) -> LifecycleEvent.State {
        var current = LifecycleEvent.State.active
        for transition in transitions {
            guard transition.day <= day else { break }
            current = transition.state
        }
        return current
    }

    public func isActive(on day: DayKey) -> Bool {
        state(on: day) == .active
    }

    /// The day this habit joined its routine, as of `day`, for the lock-in gate's ordering.
    ///
    /// Its start day, unless it has since been restored from the archive, in which case the
    /// day of the most recent restore. Restoring is adding the habit back, so it queues behind
    /// everything already in the routine and is the one the gate judges next. Resuming from a
    /// pause does not move it, because a paused habit never left the gate's view.
    public func joinedRoutine(asOf day: DayKey) -> DayKey {
        var joined = startedOn
        var previous = LifecycleEvent.State.active
        for transition in transitions {
            guard transition.day <= day else { break }
            if previous == .archived, transition.state != .archived { joined = transition.day }
            previous = transition.state
        }
        return joined
    }
}
