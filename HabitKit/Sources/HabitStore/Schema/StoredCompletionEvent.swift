import Foundation
import HabitKit
import SwiftData

/// The stored form of `CompletionEvent`.
///
/// ### Deduplication without a unique constraint
///
/// CloudKit has no unique constraints and SwiftData forbids `@Attribute(.unique)` on a synced
/// model, so nothing in the storage layer stops the same completion existing twice. Two
/// devices that both record Tuesday write two records, and both sync down.
///
/// The defence is in two places, and both are needed:
///
/// 1. **On write**, `eventID` is content-addressed from `(habitID, dayKey, slotIndex)`, and
///    the writer merges into any row already carrying that id rather than inserting beside it.
///    That keeps one device's own store clean.
/// 2. **On read**, the fold runs the domain's `resolved()` over whatever it finds, because
///    step 1 cannot stop a peer's row arriving later. This is the one that actually has to
///    be right.
///
/// A retraction deliberately shares its `eventID` with the completion it undoes. They are two
/// assertions about the same day, and `resolved()` picks by `recordedAt`.
@Model
public final class StoredCompletionEvent {

    /// Content-addressed: `habitID|dayKey|slotIndex`. Shared by an assertion and its retraction.
    public var eventID: String = ""

    public var habitID: UUID = UUID()

    /// `DayKey.rawValue`. `0` is not a valid day; see `StoredHabit.startedOnRaw`.
    public var dayKeyRaw: Int = 0

    public var slotIndex: Int = 0

    public var statusRaw: String = CompletionEvent.Status.completed.rawValue

    /// When the habit was done. Meaningless on a retraction.
    public var occurredAt: Date = Date.distantPast

    /// When the assertion was made. This is what resolves conflicts, and it is the reason
    /// a correction beats the completion it corrects regardless of arrival order.
    public var recordedAt: Date = Date.distantPast

    public var timeZoneIdentifier: String = ""

    public var schemaVersion: Int = HabitSchemaV1.versionIdentifier.major
    public var payloadJSON: String?

    public init(
        eventID: String = "",
        habitID: UUID = UUID(),
        dayKeyRaw: Int = 0,
        slotIndex: Int = 0,
        statusRaw: String = CompletionEvent.Status.completed.rawValue,
        occurredAt: Date = .distantPast,
        recordedAt: Date = .distantPast,
        timeZoneIdentifier: String = "",
        schemaVersion: Int = HabitSchemaV1.versionIdentifier.major,
        payloadJSON: String? = nil
    ) {
        self.eventID = eventID
        self.habitID = habitID
        self.dayKeyRaw = dayKeyRaw
        self.slotIndex = slotIndex
        self.statusRaw = statusRaw
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.schemaVersion = schemaVersion
        self.payloadJSON = payloadJSON
    }
}

/// The stored form of `LifecycleEvent`.
///
/// Same dedup story as `StoredCompletionEvent`, with one difference that matters: where two
/// devices disagree about a day, the **later** decision wins outright. A completion is a fact
/// that happened, so its earliest `occurredAt` survives. A lifecycle state is an intention,
/// and an intention can simply be changed.
@Model
public final class StoredLifecycleEvent {

    /// Content-addressed: `habitID|dayKey`. One state per habit per day.
    public var eventID: String = ""

    public var habitID: UUID = UUID()
    public var dayKeyRaw: Int = 0
    public var stateRaw: String = LifecycleEvent.State.active.rawValue
    public var occurredAt: Date = Date.distantPast
    public var timeZoneIdentifier: String = ""

    public var schemaVersion: Int = HabitSchemaV1.versionIdentifier.major
    public var payloadJSON: String?

    public init(
        eventID: String = "",
        habitID: UUID = UUID(),
        dayKeyRaw: Int = 0,
        stateRaw: String = LifecycleEvent.State.active.rawValue,
        occurredAt: Date = .distantPast,
        timeZoneIdentifier: String = "",
        schemaVersion: Int = HabitSchemaV1.versionIdentifier.major,
        payloadJSON: String? = nil
    ) {
        self.eventID = eventID
        self.habitID = habitID
        self.dayKeyRaw = dayKeyRaw
        self.stateRaw = stateRaw
        self.occurredAt = occurredAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.schemaVersion = schemaVersion
        self.payloadJSON = payloadJSON
    }
}
