import Foundation
import HabitKit

extension StoredRoutineStep {

    /// The content address of a step. One helper, so the writer and the checker cannot drift.
    public static func stepID(runID: String, habitID: UUID) -> String {
        "\(runID)|\(habitID.uuidString)"
    }

    public convenience init(_ step: RoutineStep, runID: String) {
        self.init(
            stepID: Self.stepID(runID: runID, habitID: step.habitID),
            habitID: step.habitID,
            position: step.position,
            startedAt: step.startedAt,
            endedAt: step.endedAt
        )
    }

    /// Overwrites the clock and the sequence position, never the identity.
    public func update(from step: RoutineStep) {
        position = step.position
        startedAt = step.startedAt
        endedAt = step.endedAt
    }

    public func toDomain() -> RoutineStep {
        RoutineStep(habitID: habitID, position: position, startedAt: startedAt, endedAt: endedAt)
    }
}

extension StoredRoutineRun {

    public convenience init(_ run: RoutineRun) {
        self.init(
            runID: run.id,
            routineRaw: run.routine.rawValue,
            dayKeyRaw: run.dayKey.rawValue,
            startedAt: run.startedAt,
            endedAt: run.endedAt,
            timeZoneIdentifier: run.timeZoneIdentifier,
            steps: run.steps.map { StoredRoutineStep($0, runID: run.id) }
        )
    }

    /// Overwrites the run's own clock. Steps are **not** touched here.
    ///
    /// Reconciling steps is the writer's job, because it needs the context this method does
    /// not have: a step absent from `run` means "not reached yet" far more often than it
    /// means "deleted", and under sync it can also mean "that device has not heard about it".
    /// Removing one is an explicit operation rather than a side effect of an update.
    public func update(from run: RoutineRun) {
        routineRaw = run.routine.rawValue
        startedAt = run.startedAt
        endedAt = run.endedAt
        timeZoneIdentifier = run.timeZoneIdentifier
    }

    public func toDomain() throws -> RoutineRun {
        let record = "StoredRoutineRun(\(runID))"

        guard let dayKey = DayKey(validating: dayKeyRaw) else {
            throw StoreMappingError.invalidDayKey(record: record, field: "dayKeyRaw", raw: dayKeyRaw)
        }
        guard let routine = RoutineSlot(rawValue: routineRaw) else {
            throw StoreMappingError.unknownRawValue(record: record, field: "routineRaw", raw: routineRaw)
        }

        let run = RoutineRun(
            routine: routine,
            dayKey: dayKey,
            startedAt: startedAt,
            endedAt: endedAt,
            timeZoneIdentifier: timeZoneIdentifier,
            // Sorted on the way out, because a SwiftData fetch has no inherent order and
            // reporting that reshuffled between launches would be its own small bug.
            steps: (steps ?? []).map { $0.toDomain() }
        ).normalizedStepOrder()

        guard run.id == runID else {
            throw StoreMappingError.identifierMismatch(record: record, stored: runID, derived: run.id)
        }
        return run
    }
}

extension RoutineRun {
    /// The same run with its steps in presentation order.
    fileprivate func normalizedStepOrder() -> RoutineRun {
        var copy = self
        copy.steps = orderedSteps
        return copy
    }
}
