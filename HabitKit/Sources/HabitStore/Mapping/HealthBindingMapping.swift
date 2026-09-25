import Foundation
import HabitKit

extension StoredHealthBinding {

    public convenience init(_ binding: HealthBinding) {
        self.init(
            habitID: binding.habitID,
            signalRaw: binding.signal.rawValue,
            externalIdentifier: binding.externalIdentifier,
            lastReconciledDayRaw: binding.lastReconciledDay.rawValue
        )
    }

    /// Overwrites this record in place. `habitID` is identity and is not touched.
    public func update(from binding: HealthBinding) {
        signalRaw = binding.signal.rawValue
        externalIdentifier = binding.externalIdentifier
        lastReconciledDayRaw = binding.lastReconciledDay.rawValue
    }

    public func toDomain() throws -> HealthBinding {
        let record = "StoredHealthBinding(\(habitID))"
        guard let signal = HealthSignal(rawValue: signalRaw) else {
            throw StoreMappingError.unknownRawValue(record: record, field: "signalRaw", raw: signalRaw)
        }
        // The default of 0 is what a binding never written through `init(_:)` reads as.
        // Accepting it would make the next backfill reach back to year zero, and the cap is
        // the only thing that would stop it.
        guard let day = DayKey(validating: lastReconciledDayRaw) else {
            throw StoreMappingError.invalidDayKey(
                record: record, field: "lastReconciledDayRaw", raw: lastReconciledDayRaw)
        }
        return HealthBinding(
            habitID: habitID,
            signal: signal,
            externalIdentifier: externalIdentifier,
            lastReconciledDay: day
        )
    }
}
