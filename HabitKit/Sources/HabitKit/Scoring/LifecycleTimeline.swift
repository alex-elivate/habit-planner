import Foundation

/// A habit's lifecycle log folded into a question you can ask about any single day.
public struct LifecycleTimeline: Hashable, Sendable {
    public struct Transition: Hashable, Sendable {
        public let day: DayKey
        public let state: LifecycleEvent.State
    }

    public let startedOn: DayKey

    /// Ascending by day, one per day, with consecutive repeats of the same state removed.
    public let transitions: [Transition]

    public init(startedOn: DayKey, events: some Sequence<LifecycleEvent>) {
        self.startedOn = startedOn

        var collapsed: [Transition] = []
        for event in Array(events).deduplicated() where event.dayKey >= startedOn {
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
}
