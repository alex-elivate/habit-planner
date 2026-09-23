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

    /// Who made this assertion: the person directly, or an outside signal proposing.
    ///
    /// A fact about this record, unlike `Habit.completionSource`, which is a mutable
    /// expectation about the habit. That difference is why this field has to exist rather
    /// than being read off the habit: flipping a habit to `.automatic` would otherwise
    /// retroactively relabel every completion the person ticked by hand.
    ///
    /// Nothing scores it and nothing in the lock-in gate may ever read it. It is here so
    /// history stays answerable, and because a field cannot be added to a frozen CloudKit
    /// schema retroactively for records already written.
    public let source: CompletionSource

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
        source: CompletionSource = .manual,
        occurredAt: Date,
        recordedAt: Date? = nil,
        timeZoneIdentifier: String
    ) {
        self.habitID = habitID
        self.dayKey = dayKey
        self.slotIndex = slotIndex
        self.status = status
        self.source = source
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt ?? occurredAt
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    /// Records a completion happening now, resolving the civil day in `timeZone`.
    public init(
        habitID: UUID,
        slotIndex: Int = 0,
        status: Status = .completed,
        source: CompletionSource = .manual,
        at instant: Date,
        in timeZone: TimeZone
    ) {
        self.init(
            habitID: habitID,
            dayKey: DayKey(instant, in: timeZone),
            slotIndex: slotIndex,
            status: status,
            source: source,
            occurredAt: instant,
            recordedAt: instant,
            timeZoneIdentifier: timeZone.identifier
        )
    }

    /// Undoes this assertion, as of `instant`.
    ///
    /// The retraction's own source defaults to `.manual`, because undoing is something a
    /// person does. It is not inherited from the assertion being undone: "a signal proposed
    /// this" and "somebody took it back" are different facts, and the second is the one this
    /// record states.
    public func retracted(at instant: Date, source: CompletionSource = .manual) -> CompletionEvent {
        CompletionEvent(
            habitID: habitID,
            dayKey: dayKey,
            slotIndex: slotIndex,
            status: .retracted,
            source: source,
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

extension CompletionEvent {
    /// A total order over assertions about the same day, latest last.
    ///
    /// Total on purpose. `max(by:)` over a partial order keeps whichever element it saw
    /// first, so two devices folding the same three records in different arrival orders
    /// would settle on different survivors and then overwrite each other through CloudKit
    /// indefinitely. Every field that distinguishes two assertions is a tiebreak here, so
    /// the fold has exactly one answer regardless of the order it meets them in.
    static func assertedEarlier(_ lhs: CompletionEvent, _ rhs: CompletionEvent) -> Bool {
        if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt < rhs.recordedAt }
        // A tie means two devices asserted at the same instant. Prefer the retraction, so
        // an undo is never lost to a coin flip.
        if lhs.status != rhs.status { return lhs.status == .completed }
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        if lhs.source != rhs.source { return lhs.source == .manual }
        return lhs.timeZoneIdentifier < rhs.timeZoneIdentifier
    }
}

extension Collection<CompletionEvent> {
    /// One assertion per habit per day, resolving corrections and sync duplicates.
    ///
    /// The survivor is a **merge of two pairs**, not a choice between records, because the
    /// fields answer two different questions:
    ///
    /// - `status`, `source` and `recordedAt` describe *the assertion*, and come from the one
    ///   asserted last. That is what makes a retraction beat the completion it undoes, and a later
    ///   re-completion beat that.
    /// - `occurredAt` and `timeZoneIdentifier` describe *the doing*, and come from the
    ///   earliest completion asserted. A completion arriving twice keeps the moment the
    ///   habit was actually done, and the place the person was standing, rather than
    ///   whenever the second device got around to syncing.
    ///
    /// Returning the earliest record *whole* is the obvious shortcut and it is wrong. It
    /// carries that record's `recordedAt` along with its `occurredAt`, which silently winds
    /// the survivor's clock backwards. In memory nothing notices, because nothing reads
    /// `recordedAt` after a fold. A store does: it persists the survivor and then resolves
    /// the *next* conflict against it, so a stale retraction beats a newer completion and
    /// the day flips to not-done. Two devices receiving the same records in different orders
    /// reached different answers and fought over the row.
    ///
    /// The practical requirement is that folding incrementally has to equal folding the whole
    /// set at once. Merging both pairs is what makes that true.
    public func resolved() -> [CompletionEvent] {
        Dictionary(grouping: self, by: \.id)
            .values
            .compactMap { group -> CompletionEvent? in
                guard let latest = group.max(by: CompletionEvent.assertedEarlier) else { return nil }

                // Earliest across *every* assertion, not merely the completed ones.
                //
                // Restricting it to completions loses the moment as soon as a retraction
                // wins, because the single surviving record is then a retraction and the
                // original `occurredAt` is gone. A later re-completion from another device
                // has nothing to restore it from, so the day comes back with the wrong
                // moment and two devices disagree. `retracted(at:)` carries the completion's
                // own `occurredAt` forward precisely so this stays available.
                //
                // It is also what the rule has always said: the earliest *asserted*.
                let earliest = group.min { lhs, rhs in
                    if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
                    return lhs.timeZoneIdentifier < rhs.timeZoneIdentifier
                }
                guard let earliest else { return latest }

                return CompletionEvent(
                    habitID: latest.habitID,
                    dayKey: latest.dayKey,
                    slotIndex: latest.slotIndex,
                    status: latest.status,
                    source: latest.source,
                    occurredAt: earliest.occurredAt,
                    recordedAt: latest.recordedAt,
                    timeZoneIdentifier: earliest.timeZoneIdentifier
                )
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
