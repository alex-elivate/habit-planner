import Foundation

/// A record that a habit was completed. Append-only and immutable once created.
///
/// The identifier is derived from the content rather than generated, so the same logical
/// completion arriving twice by different routes (CloudKit from the Mac, WatchConnectivity
/// from the watch) collapses to one row. CloudKit offers no unique constraints, so this
/// determinism is the only thing standing between us and double-counted days.
public struct CompletionEvent: Identifiable, Hashable, Codable, Sendable {
    public let habitID: UUID

    /// The civil day this counts toward, resolved in `timeZoneIdentifier` at the moment
    /// of completion.
    public let dayKey: DayKey

    /// Which occurrence of this habit within the day, starting at zero.
    ///
    /// This is *not* the habit's position in the routine. Display order changes when the
    /// person reorders their morning, and an identifier that moved with it would fork every
    /// past completion into a duplicate.
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

extension Collection<CompletionEvent> {
    /// Collapses duplicates that arrived by more than one sync path, keeping the earliest
    /// recorded instant for each logical completion.
    public func deduplicated() -> [CompletionEvent] {
        Dictionary(grouping: self, by: \.id)
            .values
            .compactMap { $0.min(by: { $0.occurredAt < $1.occurredAt }) }
            .sorted { ($0.dayKey, $0.occurredAt) < ($1.dayKey, $1.occurredAt) }
    }
}

private func < (lhs: (DayKey, Date), rhs: (DayKey, Date)) -> Bool {
    lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
}
