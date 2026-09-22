import Foundation
import HabitKit
import SwiftData

/// The stored form of `Habit`.
///
/// ### Why every field looks like this
///
/// CloudKit-backed SwiftData imposes rules that are not suggestions, and this schema freezes
/// the first time it is promoted to the production environment. After that, fields may be
/// added but never renamed or removed. So:
///
/// - **Every property is optional or has a default.** CloudKit cannot express a required
///   field, because a record can always arrive from a peer that has not been told about it.
/// - **No `@Attribute(.unique)`.** It is rejected outright. Deduplication is done by hand
///   against `habitID`, which is the whole reason identifiers here are content-addressed.
/// - **Nothing derived is stored.** No streak, no lock-in flag, no tally. Those are folded
///   from the logs at read time, every time. See the README.
/// - **Enums are stored as their raw strings**, not as `Codable` blobs, so a record is
///   readable in the CloudKit dashboard and an unknown future case fails loudly at the
///   mapping boundary instead of corrupting a decode.
@Model
public final class StoredHabit {

    /// The domain identity. Not a SwiftData unique constraint, because CloudKit forbids one.
    public var habitID: UUID = UUID()

    public var title: String = ""
    public var cue: String?
    public var twoMinuteVersion: String?
    public var identityStatement: String?

    public var routineRaw: String = RoutineSlot.morning.rawValue

    /// Display position. Mutable and safe to reorder, and no rule may ever read it.
    public var order: Int = 0

    /// `Schedule` flattened to two primitives rather than stored as an encoded blob.
    ///
    /// The days are a seven-bit mask because `Set<Weekday>` has no stable iteration order,
    /// and an encoding that changes on every save manufactures sync conflicts on records
    /// nobody edited. Flattening also keeps the frozen schema inspectable in the dashboard.
    public var scheduleKindRaw: String = StoredSchedule.Kind.daily.rawValue
    public var scheduleDayMask: Int = 0

    public var completionSourceRaw: String = CompletionSource.manual.rawValue

    /// `DayKey.rawValue`. Defaults to `0`, which is deliberately **not** a valid day.
    ///
    /// Zero is what a missing or zeroed CloudKit `Int64` reads as, and `DayKey(rawValue: 0)`
    /// has an ordinal of -719560. A habit that started then folds into a 740,000 element
    /// array inside a widget extension under a tight memory budget. Mapping rejects it.
    public var startedOnRaw: Int = 0

    // MARK: Escape hatches

    /// Which schema version wrote this record.
    ///
    /// Present from day one because the frozen schema cannot be renamed later. A reader that
    /// meets a higher number than it understands knows to leave the record alone rather than
    /// round-trip it through a lossy mapping and write the loss back.
    public var schemaVersion: Int = HabitSchemaV1.versionIdentifier.major

    /// Spare capacity for a field that does not exist yet.
    ///
    /// Adding a property to a frozen CloudKit schema is allowed, so this is not the only way
    /// out. It is here for the case where a field must be added and shipped to devices
    /// already running an older build, which cannot see a genuinely new column.
    public var payloadJSON: String?

    public init(
        habitID: UUID = UUID(),
        title: String = "",
        cue: String? = nil,
        twoMinuteVersion: String? = nil,
        identityStatement: String? = nil,
        routineRaw: String = RoutineSlot.morning.rawValue,
        order: Int = 0,
        scheduleKindRaw: String = StoredSchedule.Kind.daily.rawValue,
        scheduleDayMask: Int = 0,
        completionSourceRaw: String = CompletionSource.manual.rawValue,
        startedOnRaw: Int = 0,
        schemaVersion: Int = HabitSchemaV1.versionIdentifier.major,
        payloadJSON: String? = nil
    ) {
        self.habitID = habitID
        self.title = title
        self.cue = cue
        self.twoMinuteVersion = twoMinuteVersion
        self.identityStatement = identityStatement
        self.routineRaw = routineRaw
        self.order = order
        self.scheduleKindRaw = scheduleKindRaw
        self.scheduleDayMask = scheduleDayMask
        self.completionSourceRaw = completionSourceRaw
        self.startedOnRaw = startedOnRaw
        self.schemaVersion = schemaVersion
        self.payloadJSON = payloadJSON
    }
}
