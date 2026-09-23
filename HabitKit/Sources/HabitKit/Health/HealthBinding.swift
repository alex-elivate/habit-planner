import Foundation

/// The kind of outside signal that can propose a habit's completion.
public enum HealthSignal: String, Hashable, Codable, Sendable, CaseIterable {
    /// A workout of one activity type, such as a walk.
    case workout
    /// A dose of one medication logged as taken in Apple Health.
    case medication
}

/// What to ask HealthKit about for one habit, on this device.
///
/// Stored only in the local health store, never in iCloud. See `StoredHealthBinding`.
public struct HealthBinding: Hashable, Sendable {
    public let habitID: UUID

    public var signal: HealthSignal

    /// Which workout type or which medication.
    ///
    /// Opaque to this package. For a medication it is an archived HealthKit concept identifier,
    /// which has no public initialiser and so cannot be rebuilt from anything readable.
    public var externalIdentifier: String?

    /// The last day the launch backfill has already covered.
    ///
    /// Starts at the day the binding was made, so linking a habit to Health never rewrites the
    /// history before the link existed.
    public var lastReconciledDay: DayKey

    public init(
        habitID: UUID,
        signal: HealthSignal,
        externalIdentifier: String? = nil,
        lastReconciledDay: DayKey
    ) {
        self.habitID = habitID
        self.signal = signal
        self.externalIdentifier = externalIdentifier
        self.lastReconciledDay = lastReconciledDay
    }
}

/// The bounded catch-up that fills days the app was never opened.
///
/// The runner checks Health when a step is on screen, which is immediate and lets the person
/// confirm. What that leaves is a day the app was not opened at all, and this covers it.
///
/// Every event it produces goes through the store's `propose`, which writes only where the day
/// carries no assertion at all. That rule, not anything here, is what keeps a backfill from
/// re-ticking a day somebody deliberately un-ticked.
public enum HealthBackfill {
    /// The furthest back a single catch-up reaches.
    ///
    /// Bounded because a late arrival changes the lock-in assessment. A week of walks turning
    /// up is reasonable. A quarter of them, the day someone grants access, would swing the gate
    /// on history the person never saw counted.
    public static let maximumDays = 7

    /// The settled days still to cover, or `nil` if there are none.
    ///
    /// Today is never included. It is still open, and the runner handles it with the person
    /// looking at the result.
    public static func daysToReconcile(
        _ binding: HealthBinding,
        today: DayKey
    ) -> ClosedRange<DayKey>? {
        let yesterday = today.advanced(by: -1)
        let first = max(binding.lastReconciledDay.advanced(by: 1), today.advanced(by: -maximumDays))
        guard first <= yesterday else { return nil }
        return first...yesterday
    }

    /// Completions to propose from the instants at which Health saw the signal.
    ///
    /// One per day, at the earliest instant seen that day, and only on days the habit was due
    /// and active. A walk on a rest day is still a walk, but it is not this habit.
    ///
    /// Each instant's day is resolved in `timeZone`, the zone the person is in now. Health does
    /// not say where a sample was taken, so this is the best available answer rather than a
    /// guess the record pretends is exact, and the zone is written onto the event so the
    /// choice stays visible.
    public static func proposals(
        for history: HabitHistory,
        in days: ClosedRange<DayKey>,
        signalInstants: some Sequence<Date>,
        recordedAt: Date,
        timeZone: TimeZone
    ) -> [CompletionEvent] {
        var earliest: [DayKey: Date] = [:]
        for instant in signalInstants {
            let day = DayKey(instant, in: timeZone)
            guard days.contains(day),
                  history.habit.isScheduled(on: day),
                  history.lifecycle.isActive(on: day)
            else { continue }
            earliest[day] = min(earliest[day] ?? instant, instant)
        }
        return earliest
            .sorted { $0.key < $1.key }
            .map { day, instant in
                CompletionEvent(
                    habitID: history.habit.id,
                    dayKey: day,
                    source: .automatic,
                    occurredAt: instant,
                    recordedAt: recordedAt,
                    timeZoneIdentifier: timeZone.identifier
                )
            }
    }
}
