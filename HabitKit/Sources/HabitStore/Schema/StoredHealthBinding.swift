import Foundation
import SwiftData

/// What to ask HealthKit about, for a habit that expects an outside signal.
///
/// ### This model never reaches iCloud
///
/// It lives in its own store, opened with `cloudKitDatabase: .none`, and it is the only
/// reason that second store exists. App Store guideline 5.1.3(ii) says an app "may not store
/// personal health information in iCloud", and `externalIdentifier` on a medication habit
/// names a drug the person takes. That is the strongest personal health information anywhere
/// in this app.
///
/// ### Why this is the only thing kept
///
/// Everything else a reconciliation might want turns out to be derivable or unnecessary:
///
/// - **A ledger of consumed sample identifiers** is not needed. Completion identifiers are
///   content-addressed from `(habitID, dayKey, slotIndex)`, so re-running a backfill produces
///   the identifier that is already there. Idempotence is structural, not bookkept. The one
///   real hazard is a backfill overwriting somebody's correction, and the guard against that
///   is a rule rather than stored state: reconciliation writes only where the day carries no
///   assertion at all.
/// - **Dose status and sample durations** are not needed. The app owns "done or not done",
///   and nothing else. A duration the app cares about is measured by `StoredRoutineStep` from
///   our own clock. A day backfilled without a run has no duration, which is honest.
///
/// A binding is also genuinely per-device. HealthKit authorisation is per-device and
/// per-medication, and macOS has no HealthKit at all, so syncing one would be meaningless
/// even if it were allowed.
@Model
public final class StoredHealthBinding {

    public var habitID: UUID = UUID()

    /// Which kind of signal proposes this habit: a workout, a medication dose, a mindful
    /// minute. Kept as a string so an unknown future case fails at the mapping boundary
    /// rather than corrupting a decode.
    public var signalRaw: String = ""

    /// The specific thing to query, where the signal needs one. A medication concept
    /// identifier lands here. This is the field that must never sync.
    public var externalIdentifier: String?

    /// How far the bounded launch reconciliation has already caught up, as `DayKey.rawValue`.
    ///
    /// Bounded deliberately. Granting access three months in should not rewrite a quarter of
    /// the history and retroactively swing the lock-in gate.
    public var lastReconciledDayRaw: Int = 0

    public init(
        habitID: UUID = UUID(),
        signalRaw: String = "",
        externalIdentifier: String? = nil,
        lastReconciledDayRaw: Int = 0
    ) {
        self.habitID = habitID
        self.signalRaw = signalRaw
        self.externalIdentifier = externalIdentifier
        self.lastReconciledDayRaw = lastReconciledDayRaw
    }
}
