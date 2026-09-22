import Foundation

/// A record that a habit changed state. Append-only and immutable, like `CompletionEvent`.
///
/// Lifecycle is a log rather than a field on `Habit` for the same reason completions are.
/// A mutable `pausedOn` cannot describe a pause that ended, so resuming either replays the
/// paused days as misses or freezes the habit forever. A log describes any number of pauses
/// and survives last-writer-wins replication, because nothing is ever overwritten.
public struct LifecycleEvent: Identifiable, Codable, Sendable {
    public enum State: String, Hashable, Codable, Sendable, CaseIterable {
        /// Due on its schedule, and counted.
        case active
        /// Off the hook. These days are not scheduled, so they accrue no misses.
        case paused
        /// Retired. History before this day still counts, nothing after it does.
        case archived
    }

    public let habitID: UUID

    /// The civil day the change took effect, resolved in `timeZoneIdentifier`.
    public let dayKey: DayKey

    /// The state entered on this day.
    public let state: State

    public let occurredAt: Date
    public let timeZoneIdentifier: String

    /// One state per habit per day.
    ///
    /// The day is the finest granularity anything in the domain reads, so pausing and
    /// resuming within a single day is a no-op by construction rather than by accident.
    /// Where two devices disagree about a day, the later decision wins, which is the
    /// opposite of `CompletionEvent` and deliberately so: a completion is a fact that
    /// happened, a lifecycle state is an intention that can be changed.
    public var id: String {
        "\(habitID.uuidString)|\(dayKey.rawValue)"
    }

    public init(
        habitID: UUID,
        dayKey: DayKey,
        state: State,
        occurredAt: Date,
        timeZoneIdentifier: String
    ) {
        self.habitID = habitID
        self.dayKey = dayKey
        self.state = state
        self.occurredAt = occurredAt
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public init(habitID: UUID, state: State, at instant: Date, in timeZone: TimeZone) {
        self.init(
            habitID: habitID,
            dayKey: DayKey(instant, in: timeZone),
            state: state,
            occurredAt: instant,
            timeZoneIdentifier: timeZone.identifier
        )
    }
}

extension LifecycleEvent: Hashable {
    /// Identity is the content-addressed `id`, so a synthesized `==` cannot disagree with it.
    public static func == (lhs: LifecycleEvent, rhs: LifecycleEvent) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension Collection<LifecycleEvent> {
    /// Collapses to one event per habit per day, keeping the last decision made that day.
    public func deduplicated() -> [LifecycleEvent] {
        Dictionary(grouping: self, by: \.id)
            .values
            .compactMap { group in
                group.max { lhs, rhs in
                    if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
                    return lhs.state.rawValue < rhs.state.rawValue
                }
            }
            .sorted { $0.dayKey == $1.dayKey ? $0.id < $1.id : $0.dayKey < $1.dayKey }
    }
}
