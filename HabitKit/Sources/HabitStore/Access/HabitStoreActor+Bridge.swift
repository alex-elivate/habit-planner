import Foundation
import HabitKit
import SwiftData

/// What a merge changed, and what it could not read.
public struct MergeResult: Sendable {
    /// Rows inserted or rewritten. Zero means the store already knew everything it was sent.
    public let written: Int
    public let skipped: [StoreMappingError]
}

/// The store's side of the watch bridge.
///
/// Merging a payload is the same operation as CloudKit delivering a peer's rows, and it runs
/// through the same domain rules: completions fold on `recordedAt`, lifecycle keeps the later
/// decision, runs combine by `RoutineRun.merged(with:)`. Nothing here decides a conflict its
/// own way, so the watch and the phone cannot drift apart by applying different rules.
///
/// Every merge only adds or combines. Nothing is deleted except duplicate rows collapsed into
/// the one that survives, which is the same thing every write in this store already does.
extension HabitStoreActor {

    // MARK: - Building payloads

    /// Everything the watch needs, as of `generatedAt`.
    public func watchSnapshot(today: DayKey, generatedAt: Date) throws -> WatchSnapshot {
        // Yesterday as well as today, because an evening run past midnight belongs to the day
        // it began.
        let earliestRun = today.advanced(by: -1)
        return WatchSnapshot(
            generatedAt: generatedAt,
            habits: try loadHabits().values,
            completions: try loadCompletionEvents().values,
            lifecycle: try loadLifecycleEvents().values,
            runs: try loadRoutineRuns().values.filter { $0.dayKey >= earliestRun },
            planned: try loadPlannedHabits().values
        )
    }

    /// Every completion and run on or after `earliestDay`.
    public func watchReport(from earliestDay: DayKey) throws -> WatchReport {
        WatchReport(
            earliestDay: earliestDay,
            completions: try loadCompletionEvents().values.filter { $0.dayKey >= earliestDay },
            runs: try loadRoutineRuns().values.filter { $0.dayKey >= earliestDay }
        )
    }

    // MARK: - Merging payloads

    /// Folds a snapshot from the phone into the watch's replica.
    @discardableResult
    public func merge(_ snapshot: WatchSnapshot) throws -> MergeResult {
        var written = 0
        var skipped: [StoreMappingError] = []
        do {
            try stageHabits(snapshot.habits, written: &written, skipped: &skipped)
            try stageCompletions(snapshot.completions, written: &written, skipped: &skipped)
            try stageLifecycle(snapshot.lifecycle, written: &written, skipped: &skipped)
            try stagePlans(snapshot.planned, written: &written, skipped: &skipped)
            if modelContext.hasChanges { try commit() }
        } catch {
            modelContext.rollback()
            throw error
        }
        try mergeRuns(snapshot.runs, written: &written, skipped: &skipped)
        return MergeResult(written: written, skipped: skipped)
    }

    /// Folds a report from the watch into the phone's store.
    @discardableResult
    public func merge(_ report: WatchReport) throws -> MergeResult {
        var written = 0
        var skipped: [StoreMappingError] = []
        do {
            try stageCompletions(report.completions, written: &written, skipped: &skipped)
            if modelContext.hasChanges { try commit() }
        } catch {
            modelContext.rollback()
            throw error
        }
        try mergeRuns(report.runs, written: &written, skipped: &skipped)
        return MergeResult(written: written, skipped: skipped)
    }

    // MARK: - Staging

    // Each stage fetches its whole table once rather than once per record. A snapshot carries
    // every completion the person has ever made, and a fetch per record would scan the table
    // once for each of them, on a watch.
    //
    // A row whose content already matches the fold is left untouched. On the phone every
    // rewritten row is exported to CloudKit, and a report arrives after every step of a watch
    // routine carrying records the phone already has. Rewriting them all would re-upload the
    // same rows every few seconds.

    private func stageHabits(
        _ incoming: [Habit],
        written: inout Int,
        skipped: inout [StoreMappingError]
    ) throws {
        guard !incoming.isEmpty else { return }
        let rows = Dictionary(grouping: try modelContext.fetch(FetchDescriptor<StoredHabit>()), by: \.habitID)

        for habit in incoming {
            // Same rule as `upsert(_:)`: the earliest stored origin survives, and the incoming
            // habit never moves it. See the reasoning there.
            let ordered = (rows[habit.id] ?? []).sorted { $0.startedOnRaw < $1.startedOnRaw }
            guard let row = ordered.first else {
                modelContext.insert(StoredHabit(habit))
                written += 1
                continue
            }
            let current: Habit
            do { current = try row.toDomain() } catch let error as StoreMappingError {
                // Left in place for the build that can read it, like every unreadable row.
                skipped.append(error)
                continue
            }
            var expected = habit
            expected.startedOn = current.startedOn
            if ordered.count == 1, current == expected { continue }

            row.update(from: habit)
            for extra in ordered.dropFirst() { modelContext.delete(extra) }
            written += 1
        }
    }

    private func stageCompletions(
        _ incoming: [CompletionEvent],
        written: inout Int,
        skipped: inout [StoreMappingError]
    ) throws {
        guard !incoming.isEmpty else { return }
        let rows = Dictionary(
            grouping: try modelContext.fetch(FetchDescriptor<StoredCompletionEvent>()), by: \.eventID
        )

        for (id, assertions) in Dictionary(grouping: incoming, by: \.id) {
            var readable: [(row: StoredCompletionEvent, event: CompletionEvent)] = []
            for row in rows[id] ?? [] {
                do { readable.append((row, try row.toDomain())) }
                catch let error as StoreMappingError { skipped.append(error) }
            }

            guard let winner = (assertions + readable.map(\.event)).resolved().first else { continue }

            guard let first = readable.first else {
                modelContext.insert(StoredCompletionEvent(winner))
                written += 1
                continue
            }
            if readable.count == 1, first.event.hasSameContent(as: winner) { continue }

            first.row.update(from: winner)
            for extra in readable.dropFirst() { modelContext.delete(extra.row) }
            written += 1
        }
    }

    private func stageLifecycle(
        _ incoming: [LifecycleEvent],
        written: inout Int,
        skipped: inout [StoreMappingError]
    ) throws {
        guard !incoming.isEmpty else { return }
        let rows = Dictionary(
            grouping: try modelContext.fetch(FetchDescriptor<StoredLifecycleEvent>()), by: \.eventID
        )

        for (id, assertions) in Dictionary(grouping: incoming, by: \.id) {
            var readable: [(row: StoredLifecycleEvent, event: LifecycleEvent)] = []
            for row in rows[id] ?? [] {
                do { readable.append((row, try row.toDomain())) }
                catch let error as StoreMappingError { skipped.append(error) }
            }

            guard let winner = (assertions + readable.map(\.event)).deduplicated().first else { continue }

            guard let first = readable.first else {
                modelContext.insert(StoredLifecycleEvent(winner))
                written += 1
                continue
            }
            if readable.count == 1, first.event.hasSameContent(as: winner) { continue }

            first.row.update(from: winner)
            for extra in readable.dropFirst() { modelContext.delete(extra.row) }
            written += 1
        }
    }

    /// Combines each incoming run with the stored copy and writes only what changed.
    ///
    /// Through `upsert(_:)`, which already knows how to collapse duplicate runs, adopt steps
    /// that arrived before their run and never delete a step. Runs are few, so a write each is
    /// cheap.
    private func mergeRuns(
        _ incoming: [RoutineRun],
        written: inout Int,
        skipped: inout [StoreMappingError]
    ) throws {
        guard !incoming.isEmpty else { return }
        let stored = try loadRoutineRuns()
        skipped += stored.skipped
        let existing = Dictionary(stored.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Combined among themselves first, so two copies of one run in a payload are one write.
        let combined = Dictionary(grouping: incoming, by: \.id).values.compactMap { copies in
            copies.dropFirst().reduce(copies[0]) { $0.merged(with: $1) }
        }

        for run in combined.sorted(by: { $0.id < $1.id }) {
            guard let current = existing[run.id] else {
                try upsert(run)
                written += 1
                continue
            }
            let merged = current.merged(with: run)
            if merged.hasSameContent(as: current) { continue }
            try upsert(merged)
            written += 1
        }
    }
}

extension CompletionEvent {
    /// Every field, where `==` compares only the identifier.
    func hasSameContent(as other: CompletionEvent) -> Bool {
        id == other.id
            && status == other.status
            && source == other.source
            && occurredAt == other.occurredAt
            && recordedAt == other.recordedAt
            && timeZoneIdentifier == other.timeZoneIdentifier
    }
}

extension LifecycleEvent {
    func hasSameContent(as other: LifecycleEvent) -> Bool {
        id == other.id
            && state == other.state
            && occurredAt == other.occurredAt
            && timeZoneIdentifier == other.timeZoneIdentifier
    }
}

extension RoutineRun {
    /// Structural equality with the steps compared as a set, since a store fetch returns
    /// them in no particular order.
    func hasSameContent(as other: RoutineRun) -> Bool {
        id == other.id
            && startedAt == other.startedAt
            && endedAt == other.endedAt
            && timeZoneIdentifier == other.timeZoneIdentifier
            && Set(steps) == Set(other.steps)
    }
}
