import Foundation

/// Where a habit's completions are expected to come from.
///
/// Deliberately coarse. This says only that a habit expects an outside signal, never which
/// signal, because the specific binding for a health-backed habit names a drug or a sample
/// type and that is the strongest personal health information in the app. App Store 5.1.3(ii)
/// keeps it out of iCloud, so it lives in a local-only store instead. This field is assigned
/// by the app rather than read from HealthKit, which is what makes it safe to sync.
///
/// It is only an expectation. A habit whose signal is missing or revoked degrades to an
/// ordinary checkbox, and nothing here may ever reach the lock-in gate.
public enum CompletionSource: String, Hashable, Codable, Sendable, CaseIterable {
    /// The person ticks it themselves.
    case manual
    /// An outside signal proposes it and the person confirms. The app still writes the record.
    case automatic
}

/// A single habit inside a routine.
///
/// Everything here is an immutable fact about what the habit *is*. Nothing describes how it
/// is going. There is no streak count, no `isLockedIn`, no completion tally, and no lifecycle
/// state, because all of those are folded from logs on demand. Storing them would rest an
/// irreversible gate decision on mutable state replicated last-writer-wins, which misfires
/// quietly. Lifecycle in particular lives in `LifecycleEvent`.
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

    /// Display position within the routine.
    ///
    /// Safe to reorder freely. Nothing derives identity or any rule decision from it, which
    /// has to stay true: the gate once tiebroke on this field, so dragging a row could
    /// unlock it.
    public var order: Int

    public var schedule: Schedule

    /// Whether this habit expects an outside signal to propose its completions.
    ///
    /// Proposes, never owns. See `CompletionSource`.
    public var completionSource: CompletionSource

    /// First day this habit could be due. History before it is not counted against you.
    public var startedOn: DayKey

    public init(
        id: UUID = UUID(),
        title: String,
        cue: String? = nil,
        twoMinuteVersion: String? = nil,
        identityStatement: String? = nil,
        routine: RoutineSlot,
        order: Int,
        schedule: Schedule = .daily,
        completionSource: CompletionSource = .manual,
        startedOn: DayKey
    ) {
        self.id = id
        self.title = title
        self.cue = cue
        self.twoMinuteVersion = twoMinuteVersion
        self.identityStatement = identityStatement
        self.routine = routine
        self.order = order
        self.schedule = schedule
        self.completionSource = completionSource
        self.startedOn = startedOn
    }

    /// Whether the calendar puts this habit on the hook for `day`.
    ///
    /// Lifecycle is deliberately not consulted here. Combining the two is `HabitHistory`'s
    /// job, because only it holds the lifecycle log.
    public func isScheduled(on day: DayKey) -> Bool {
        day >= startedOn && schedule.isScheduled(on: day)
    }
}
