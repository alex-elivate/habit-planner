import Foundation
import HabitKit
import SwiftData

extension HabitStoreActor {

    /// Records a plan for a routine, or a cleared one, collapsing any other row for it.
    ///
    /// The routine is the identity, so every row for it is the same record as far as the
    /// domain is concerned, and the survivor is chosen by `PlannedHabit.supersedes`. An
    /// incoming plan older than the one stored changes nothing.
    ///
    /// - Returns: whether anything was written.
    @discardableResult
    public func record(_ plan: PlannedHabit) throws -> Bool {
        var written = 0
        var skipped: [StoreMappingError] = []
        try stagePlans([plan], written: &written, skipped: &skipped)
        guard modelContext.hasChanges else { return false }
        try commit()
        return written > 0
    }

    /// The surviving plan for each routine, cleared ones included.
    public func loadPlannedHabits() throws -> LoadResult<PlannedHabit> {
        let rows = try modelContext.fetch(FetchDescriptor<StoredPlannedHabit>())
        var values: [PlannedHabit] = []
        var skipped: [StoreMappingError] = []
        for row in rows {
            do { values.append(try row.toDomain()) }
            catch let error as StoreMappingError { skipped.append(error) }
        }
        return LoadResult(
            values: values.resolved().values.sorted { $0.routine.rawValue < $1.routine.rawValue },
            skipped: skipped
        )
    }

    /// Folds incoming plans into the stored rows, writing only where the survivor changes.
    ///
    /// Shared by `record(_:)` and the snapshot merge, so a plan arriving from the phone is
    /// decided by exactly the rule a local edit is.
    func stagePlans(
        _ incoming: [PlannedHabit],
        written: inout Int,
        skipped: inout [StoreMappingError]
    ) throws {
        guard !incoming.isEmpty else { return }
        let rows = Dictionary(
            grouping: try modelContext.fetch(FetchDescriptor<StoredPlannedHabit>()), by: \.routineRaw
        )

        for (routine, plans) in Dictionary(grouping: incoming, by: \.routine) {
            var readable: [(row: StoredPlannedHabit, plan: PlannedHabit)] = []
            for row in rows[routine.rawValue] ?? [] {
                do { readable.append((row, try row.toDomain())) }
                catch let error as StoreMappingError {
                    // Left in place for the build that can read it, like every unreadable row.
                    skipped.append(error)
                }
            }

            guard let winner = (plans + readable.map(\.plan)).resolved()[routine] else { continue }

            guard let first = readable.first else {
                modelContext.insert(StoredPlannedHabit(winner))
                written += 1
                continue
            }
            if readable.count == 1, first.plan == winner { continue }

            first.row.update(from: winner)
            for extra in readable.dropFirst() { modelContext.delete(extra.row) }
            written += 1
        }
    }
}
