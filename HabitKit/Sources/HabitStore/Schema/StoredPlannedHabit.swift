import Foundation
import HabitKit
import SwiftData

/// The stored form of `PlannedHabit`: the habit a routine will add once it unlocks.
///
/// Synced, because a plan made on the phone should be there on the Mac. It names a habit the
/// person intends to start, which is not health information, so it sits on the CloudKit side of
/// the split in `HabitSchemaV1`.
///
/// One record per routine is the intent. CloudKit cannot enforce that, so the store collapses
/// rows for the same routine on every write, and every read resolves them with the domain's own
/// `resolved()`. See `PlannedHabit` for why each field is here and why a plan is cleared rather
/// than deleted.
@Model
public final class StoredPlannedHabit {

    /// The identity. `RoutineSlot.rawValue`.
    public var routineRaw: String = RoutineSlot.morning.rawValue

    /// Empty once the plan is cleared.
    public var title: String = ""

    /// When the plan was written. The later one wins a conflict.
    public var recordedAt: Date = Date(timeIntervalSince1970: 0)

    // MARK: Escape hatches

    /// See `StoredHabit.schemaVersion`.
    public var schemaVersion: Int = HabitSchemaV1.versionIdentifier.major

    /// See `StoredHabit.payloadJSON`.
    public var payloadJSON: String?

    public init(
        routineRaw: String = RoutineSlot.morning.rawValue,
        title: String = "",
        recordedAt: Date = Date(timeIntervalSince1970: 0),
        schemaVersion: Int = HabitSchemaV1.versionIdentifier.major,
        payloadJSON: String? = nil
    ) {
        self.routineRaw = routineRaw
        self.title = title
        self.recordedAt = recordedAt
        self.schemaVersion = schemaVersion
        self.payloadJSON = payloadJSON
    }
}
