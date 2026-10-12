import Foundation
import HabitKit

extension HabitStoreActor {
    /// Every record, read in one pass on the actor so the parts agree with each other.
    public func export(at instant: Date) throws -> HabitExport {
        let habits = try loadHabits()
        let completions = try loadCompletionEvents()
        let lifecycle = try loadLifecycleEvents()
        let runs = try loadRoutineRuns()
        let plans = try loadPlannedHabits()
        let skipped = habits.skipped + completions.skipped + lifecycle.skipped
            + runs.skipped + plans.skipped
        return HabitExport(
            exportedAt: instant,
            habits: habits.values,
            completions: completions.values,
            lifecycle: lifecycle.values,
            routineRuns: runs.values,
            plannedHabits: plans.values,
            unreadableRecords: skipped.map(\.description)
        )
    }
}
