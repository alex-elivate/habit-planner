import Foundation

/// The habit a routine is waiting to add once its newest habit beds in.
///
/// At most one per routine, and the routine is its identity. There is no separate identifier,
/// because two devices planning a habit for the same routine are describing the same slot, and
/// giving each plan its own identity would leave both standing with nothing to choose between
/// them.
///
/// ### Nothing is ever deleted
///
/// Clearing a plan writes an empty title rather than removing the record. Deletion would break
/// the watch snapshot's rule that a newer snapshot is always a superset of an older one, and a
/// deletion racing an edit on another device resurrects the edit anyway. A cleared plan is an
/// assertion like any other, and the latest assertion wins.
///
/// ### Why each field is stored
///
/// - `routine` is the identity. Without it there is nothing to say which gate the plan waits on.
/// - `title` is the plan itself.
/// - `recordedAt` decides between two devices that both wrote. Without it the survivor has to be
///   chosen by content, and an edit made on one device could lose to an older value on another
///   for good.
///
/// Nothing about it is scored, and the lock-in gate never reads it. It is a note to yourself.
public struct PlannedHabit: Hashable, Codable, Sendable {
    public let routine: RoutineSlot
    public let title: String
    public let recordedAt: Date

    public init(routine: RoutineSlot, title: String, recordedAt: Date) {
        self.routine = routine
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.recordedAt = recordedAt
    }

    private enum CodingKeys: String, CodingKey { case routine, title, recordedAt }

    /// Decoded through `init`, so a title that arrives as only whitespace is a cleared plan here
    /// just as it is when typed. The synthesized decoder would have skipped the trimming.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            routine: try container.decode(RoutineSlot.self, forKey: .routine),
            title: try container.decode(String.self, forKey: .title),
            recordedAt: try container.decode(Date.self, forKey: .recordedAt)
        )
    }

    /// A cleared plan. Written instead of deleting the record.
    public static func cleared(_ routine: RoutineSlot, at instant: Date) -> PlannedHabit {
        PlannedHabit(routine: routine, title: "", recordedAt: instant)
    }

    public var isCleared: Bool { title.isEmpty }

    /// Whether this assertion beats `other` for the same routine.
    ///
    /// The later `recordedAt` wins. The title breaks a tie so that the order is total: over a
    /// partial order `max(by:)` keeps whichever element it saw first, and two devices would
    /// then settle on different survivors and overwrite each other forever.
    public func supersedes(_ other: PlannedHabit) -> Bool {
        if recordedAt != other.recordedAt { return recordedAt > other.recordedAt }
        return title > other.title
    }
}

extension Sequence where Element == PlannedHabit {

    /// The surviving assertion for each routine, cleared ones included.
    ///
    /// Cleared plans are kept so that a store folding one record at a time can still see that
    /// the slot was emptied after an older title. Use `active` for what to show.
    public func resolved() -> [RoutineSlot: PlannedHabit] {
        var result: [RoutineSlot: PlannedHabit] = [:]
        for plan in self {
            if let kept = result[plan.routine], !plan.supersedes(kept) { continue }
            result[plan.routine] = plan
        }
        return result
    }
}

extension Dictionary where Key == RoutineSlot, Value == PlannedHabit {
    /// The plan to show for `routine`, or `nil` if there is none or it was cleared.
    public func active(for routine: RoutineSlot) -> PlannedHabit? {
        guard let plan = self[routine], !plan.isCleared else { return nil }
        return plan
    }
}
