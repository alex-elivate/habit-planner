import Foundation

/// A record that a habit was completed. Append-only and immutable once created.
///
/// The identifier is derived from the content rather than generated, so the same logical
/// completion arriving twice by different routes (CloudKit from the Mac, WatchConnectivity
/// from the watch) collapses to one row. CloudKit offers no unique constraints, so this
/// determinism is the only thing standing between us and double-counted days.
public struct CompletionEvent: Identifiable, Codable, Sendable {
    public let habitID: UUID

    /// The civil day this counts toward, resolved in `timeZoneIdentifier` at the moment
    /// of completion.
    public let dayKey: DayKey

    /// Which occurrence of this habit within the day, starting at zero.
    ///
    /// This is *not* the habit's position in the routine. Display order changes when the
    /// person reorders their morning, and an identifier that moved with it would fork every
    /// past completion into a duplicate.
    ///
    /// Nothing scores this. A habit is due at most once a day, so the field exists purely to
    /// keep two taps on the same habit on the same day from colliding into one identifier.
    /// Scoring a habit several times a day would need a `slotsPerDay` on `Habit` to supply
    /// the denominator, which v1 deliberately does not have.
    public let slotIndex: Int

    /// The real instant, kept for reporting on time of day. Never used to derive `dayKey`.
    public let occurredAt: Date

    /// Where the person was when they completed it, so a later timezone question is
    /// answerable rather than guessed at.
    public let timeZoneIdentifier: String

    public var id: String {
        "\(habitID.uuidString)|\(dayKey.rawValue)|\(slotIndex)"
    }

    public init(
        habitID: UUID,
        dayKey: DayKey,
        slotIndex: Int = 0,
        occurredAt: Date,
        timeZoneIdentifier: String
    ) {
        self.habitID = habitID
        self.dayKey = dayKey
        self.slotIndex = slotIndex
        self.occurredAt = occurredAt
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    /// Records a completion happening now, resolving the civil day in `timeZone`.
    public init(
        habitID: UUID,
        slotIndex: Int = 0,
        at instant: Date,
        in timeZone: TimeZone
    ) {
        self.init(
            habitID: habitID,
            dayKey: DayKey(instant, in: timeZone),
            slotIndex: slotIndex,
            occurredAt: instant,
            timeZoneIdentifier: timeZone.identifier
        )
    }
}

extension CompletionEvent: Hashable {
    /// Delegates to `id` so identity cannot disagree with the content-addressed identifier.
    ///
    /// The synthesized version covered `occurredAt` and `timeZoneIdentifier`, so the same
    /// completion arriving from the Mac and from the Watch compared unequal and landed in a
    /// `Set` as two entries. Any count-based consumer reaching for `Set` or `contains`
    /// instead of `deduplicated()` would have double-counted the day, silently, along
    /// exactly the sync path this design exists to defend.
    public static func == (lhs: CompletionEvent, rhs: CompletionEvent) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension Collection<CompletionEvent> {
    /// Collapses duplicates that arrived by more than one sync path, keeping the earliest
    /// recorded instant for each logical completion.
    ///
    /// `id` breaks the final tie. Without it the sort key was not a total order, and since
    /// `Array.sorted` is not stable and `Dictionary.values` iteration varies per process, a
    /// single "complete my whole routine" tap, which stamps every event with one `Date()`,
    /// produced a different ordering on every run.
    public func deduplicated() -> [CompletionEvent] {
        Dictionary(grouping: self, by: \.id)
            .values
            .compactMap { $0.min(by: { $0.occurredAt < $1.occurredAt }) }
            .sorted { lhs, rhs in
                if lhs.dayKey != rhs.dayKey { return lhs.dayKey < rhs.dayKey }
                if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
                return lhs.id < rhs.id
            }
    }
}
