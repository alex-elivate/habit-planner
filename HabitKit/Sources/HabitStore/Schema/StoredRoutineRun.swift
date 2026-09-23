import Foundation
import HabitKit
import SwiftData

/// The stored form of `RoutineRun`.
///
/// This is the one place the schema uses a SwiftData relationship, and the exception is
/// deliberate. Habits and their events are joined by a plain `habitID` instead, because
/// CloudKit does not guarantee that related changes save atomically: a completion that
/// arrives before its habit is still a perfectly good record, and a relationship would have
/// made it an orphan. A run and its steps are different. They are written together, in one
/// save, on one device, and a step means nothing without its run.
///
/// A run that syncs with some steps missing degrades to a run with fewer steps. That is
/// tolerable for reporting, which is all this record feeds.
@Model
public final class StoredRoutineRun {

    /// Content-addressed: `routine|dayKey`. One morning and one evening per day.
    public var runID: String = ""

    public var routineRaw: String = RoutineSlot.morning.rawValue

    /// `DayKey.rawValue`, resolved when the run started. An evening routine that runs past
    /// midnight still belongs to the day it began.
    public var dayKeyRaw: Int = 0

    public var startedAt: Date?

    /// `nil` on a routine abandoned midway, which is a normal shape rather than an error.
    public var endedAt: Date?

    public var timeZoneIdentifier: String = ""

    /// Optional with an inverse and a cascade, as CloudKit requires. `.deny` is rejected
    /// outright by a synced schema, and cascade is what the ownership actually is.
    @Relationship(deleteRule: .cascade, inverse: \StoredRoutineStep.run)
    public var steps: [StoredRoutineStep]? = []

    public var schemaVersion: Int = HabitSchemaV1.versionIdentifier.major
    public var payloadJSON: String?

    public init(
        runID: String = "",
        routineRaw: String = RoutineSlot.morning.rawValue,
        dayKeyRaw: Int = 0,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        timeZoneIdentifier: String = "",
        steps: [StoredRoutineStep]? = [],
        schemaVersion: Int = HabitSchemaV1.versionIdentifier.major,
        payloadJSON: String? = nil
    ) {
        self.runID = runID
        self.routineRaw = routineRaw
        self.dayKeyRaw = dayKeyRaw
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.steps = steps
        self.schemaVersion = schemaVersion
        self.payloadJSON = payloadJSON
    }
}

/// One habit's turn inside a stored run, with the clock on both ends.
///
/// The timestamps are captured because a completion instant cannot answer how long a walk
/// took, or how long the gap between two steps was, and neither is reconstructable later.
/// Nothing scores them yet, and that restraint is the point: rewarding a short gap would put
/// a stopwatch on health behaviours and fight the forgiving design everywhere else.
@Model
public final class StoredRoutineStep {

    /// Content-addressed: `runID|habitID`. A habit appears at most once in a run.
    ///
    /// Keyed on the habit rather than on `position`, because position describes the order
    /// the person was walked through and reordering the routine later must not fork every
    /// past step into a duplicate.
    public var stepID: String = ""

    public var habitID: UUID = UUID()

    /// The run this step belongs to, as a plain value alongside the relationship.
    ///
    /// Redundant with `stepID`, which already embeds it, and with `run`. It earns the column
    /// because it is the only way to *find* a step whose run has not arrived. CloudKit does
    /// not save related changes atomically, so a step can sync ahead of its run, and a step
    /// with a nil `run` is invisible to a fetch that starts from runs. Without this it stays
    /// invisible forever, because nothing can locate it to reattach it.
    public var runID: String = ""

    /// Where this step fell in the sequence actually presented. Nothing keys on it.
    public var position: Int = 0

    public var startedAt: Date?
    public var endedAt: Date?

    /// The inverse side of the relationship. Optional, as CloudKit requires.
    public var run: StoredRoutineRun?

    public var schemaVersion: Int = HabitSchemaV1.versionIdentifier.major
    public var payloadJSON: String?

    public init(
        stepID: String = "",
        habitID: UUID = UUID(),
        runID: String = "",
        position: Int = 0,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        run: StoredRoutineRun? = nil,
        schemaVersion: Int = HabitSchemaV1.versionIdentifier.major,
        payloadJSON: String? = nil
    ) {
        self.stepID = stepID
        self.habitID = habitID
        self.runID = runID
        self.position = position
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.run = run
        self.schemaVersion = schemaVersion
        self.payloadJSON = payloadJSON
    }
}
