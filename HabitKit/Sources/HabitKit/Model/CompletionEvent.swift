import Foundation

/// An assertion about whether a habit was completed on a given day.
///
/// Completions drive an irreversible decision, so they have to be correctable. A record you
/// cannot fix is a record you cannot trust, and automatic completion from HealthKit makes a
/// wrong tick a certainty rather than an edge case.
///
/// Correcting one never mutates or deletes anything. A retraction is another assertion about
/// the same day, and the fold takes whichever was recorded last.
public struct CompletionEvent: Identifiable, Codable, Sendable {
    public enum Status: String, Hashable, Codable, Sendable, CaseIterable {
        case completed
        case retracted
    }

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

    public let status: Status

    /// When the habit was actually done. Carries no meaning for a retraction.
    public let occurredAt: Date

    /// When this assertion was made, which is what resolves conflicts.
    ///
    /// Distinct from `occurredAt` because they answer different questions. Backfilling a
    /// completion from HealthKit a day later has an `occurredAt` of yesterday and a
    /// `recordedAt` of now.
    public let recordedAt: Date

    /// Where the person was when they completed it, so a later timezone question is
    /// answerable rather than guessed at.
    public let timeZoneIdentifier: String

    /// The day this assertion is about. Every assertion for the same day shares it.
    ///
    /// Derived from content rather than generated, so the same completion arriving from the
    /// Mac and from the Watch collapses to one. CloudKit offers no unique constraints, so
    /// this determinism is the only thing standing between us and double-counted days.
    public var id: String {
        "\(habitID.uuidString)|\(dayKey.rawValue)|\(slotIndex)"
    }

    public init(
        habitID: UUID,
        dayKey: DayKey,
        slotIndex: Int = 0,
        status: Status = .completed,
        occurredAt: Date,
        recordedAt: Date? = nil,
        timeZoneIdentifier: String
    ) {
        self.habitID = habitID
        self.dayKey = dayKey
        self.slotIndex = slotIndex
        self.status = status
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt ?? occurredAt
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    /// Records a completion happening now, resolving the civil day in `timeZone`.
    public init(
        habitID: UUID,
        slotIndex: Int = 0,
        status: Status = .completed,
        at instant: Date,
        in timeZone: TimeZone
    ) {
        self.init(
            habitID: habitID,
            dayKey: DayKey(instant, in: timeZone),
            slotIndex: slotIndex,
            status: status,
            occurredAt: instant,
            recordedAt: instant,
            timeZoneIdentifier: timeZone.identifier
        )
    }

    /// Undoes this assertion, as of `instant`.
    public func retracted(at instant: Date) -> CompletionEvent {
        CompletionEvent(
            habitID: habitID,
            dayKey: dayKey,
            slotIndex: slotIndex,
            status: .retracted,
            occurredAt: occurredAt,
            recordedAt: instant,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }
}

extension CompletionEvent: Hashable {
    /// Delegates to `id` so identity cannot disagree with the content-addressed identifier.
    ///
    /// The synthesized version covered `occurredAt` and `timeZoneIdentifier`, so the same
    /// completion arriving from the Mac and from the Watch compared unequal and landed in a
    /// `Set` as two entries. Any count-based consumer reaching for `Set` or `contains`
    /// instead of `resolved()` would have double-counted the day, silently, along exactly
    /// the sync path this design exists to defend.
    public static func == (lhs: CompletionEvent, rhs: CompletionEvent) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension Collection<CompletionEvent> {
    /// One assertion per habit per day, resolving corrections and sync duplicates.
    ///
    /// Two rules, because `occurredAt` and `recordedAt` answer different questions. Status
    /// comes from the assertion recorded last, so a retraction beats the completion it
    /// undoes and a later re-completion beats that. The surviving `occurredAt` is the
    /// earliest asserted, so a completion arriving twice keeps the moment the habit was
    /// actually done rather than whenever the second device got around to syncing.
    public func resolved() -> [CompletionEvent] {
        Dictionary(grouping: self, by: \.id)
            .values
            .compactMap { group -> CompletionEvent? in
                guard let latest = group.max(by: { lhs, rhs in
                    if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt < rhs.recordedAt }
                    // A tie means two devices asserted at the same instant. Prefer the
                    // retraction, so an undo is never lost to a coin flip.
                    return lhs.status == .completed && rhs.status == .retracted
                }) else { return nil }

                guard latest.status == .completed else { return latest }

                let earliest = group
                    .filter { $0.status == .completed }
                    .min(by: { $0.occurredAt < $1.occurredAt })
                return earliest ?? latest
            }
            .sorted { lhs, rhs in
                if lhs.dayKey != rhs.dayKey { return lhs.dayKey < rhs.dayKey }
                if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
                return lhs.id < rhs.id
            }
    }

    /// The days this habit actually counts as done, corrections applied.
    public func completedDays(for habitID: UUID) -> Set<DayKey> {
        Set(
            filter { $0.habitID == habitID }
                .resolved()
                .lazy
                .filter { $0.status == .completed }
                .map(\.dayKey)
        )
    }
}
