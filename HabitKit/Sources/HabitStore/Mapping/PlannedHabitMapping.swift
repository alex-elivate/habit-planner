import Foundation
import HabitKit

extension StoredPlannedHabit {

    public convenience init(_ plan: PlannedHabit) {
        self.init(routineRaw: plan.routine.rawValue, title: plan.title, recordedAt: plan.recordedAt)
    }

    /// Overwrites this record in place. `routineRaw` is identity and is not touched.
    public func update(from plan: PlannedHabit) {
        title = plan.title
        recordedAt = plan.recordedAt
    }

    public func toDomain() throws -> PlannedHabit {
        let record = "StoredPlannedHabit(\(routineRaw))"
        try StoreMappingError.checkVersion(schemaVersion, record: record)
        guard let routine = RoutineSlot(rawValue: routineRaw) else {
            throw StoreMappingError.unknownRawValue(record: record, field: "routineRaw", raw: routineRaw)
        }
        return PlannedHabit(routine: routine, title: title, recordedAt: recordedAt)
    }
}
