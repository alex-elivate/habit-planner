import Foundation
import HabitKit
import SwiftData

/// What a bulk read produced, and what it could not.
///
/// Failures are returned rather than swallowed. One unreadable row must not blank a widget,
/// and it must not vanish either: a store that quietly drops records is how a score ends up
/// subtly wrong with nothing anywhere saying so.
public struct LoadResult<Value: Sendable>: Sendable {
    public let values: [Value]
    public let skipped: [StoreMappingError]

    public init(values: [Value], skipped: [StoreMappingError] = []) {
        self.values = values
        self.skipped = skipped
    }

    public var hasFailures: Bool { !skipped.isEmpty }
}

/// The only writer to the store, and the only place deduplication happens.
///
/// A `@ModelActor` because `ModelContext` is not `Sendable` and Swift 6 strict concurrency is
/// on from day one. Every method here returns HabitKit value types, never `@Model` objects.
///
/// **That is a convention, not a compiler guarantee.** The `@ModelActor` macro synthesises a
/// `nonisolated let modelExecutor`, and `ModelExecutor.modelContext` is a nonisolated protocol
/// requirement, so `store.modelExecutor.modelContext` hands any caller this actor's live
/// context with no diagnostic at all. Using it concurrently with the actor segfaults.
///
/// The asymmetry is what makes it easy to miss: the compiler *does* stop `mainContext`
/// leaving the main actor, and *does* complain when a stolen context is captured in a
/// `@Sendable` closure. It stays silent in exactly the case that matters here, pulling the
/// context onto an actor the caller already occupies, which is the UI. The macro offers no
/// way to suppress the member, so: **never touch `modelExecutor` from outside this type.**
///
/// ### Deduplication
///
/// CloudKit has no unique constraints and SwiftData forbids `@Attribute(.unique)` on a synced
/// model, so nothing below this layer stops the same event existing twice. Every write here
/// collapses whatever already carries the same content-addressed identifier, and it does so
/// by calling the domain's own `resolved()` and `deduplicated()` rather than reimplementing
/// the rule. Reimplementing it would mean two copies of a subtle precedence rule that must
/// agree forever, and they would stop agreeing.
///
/// Read-side resolution still runs on top of this, because a write cannot stop a peer's row
/// arriving tomorrow.
@ModelActor
public actor HabitStoreActor {

    /// Saves, or discards the staged changes.
    ///
    /// The actor holds one context for the life of the process. Without the rollback, a
    /// single failed save leaves its changes staged and every later save re-attempts them,
    /// so one bad row poisons every write that follows it for as long as the app runs.
    private func commit() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    // MARK: - Habits

    /// Inserts a habit, or updates the one already carrying its identifier.
    public func upsert(_ habit: Habit) throws {
        let id = habit.id
        let existing = try modelContext.fetch(
            FetchDescriptor<StoredHabit>(predicate: #Predicate { $0.habitID == id })
        )
        // Duplicate habit rows come from sync, and they can disagree about `startedOn`.
        //
        // "Keep whichever the fetch returned first" is not a rule. A `FetchDescriptor` with
        // no `sortBy` has no defined order, and in practice it varies between runs on the
        // same data, so two devices kept different rows, each deleted the row the other
        // kept, and the habit's origin day flickered. `startedOn` is what the entire history
        // is counted from: keeping the later row turned 59 settled occurrences into 4, and
        // the lock-in gate reported `notEnoughHistory` for a routine months old.
        //
        // The earliest origin wins, which is both deterministic and the safe direction.
        // Counting history the habit did not have is a smaller error than erasing history
        // it did, and only the latter can silently lock a routine.
        let ordered = existing.sorted { $0.startedOnRaw < $1.startedOnRaw }
        if let row = ordered.first {
            row.update(from: habit)
            // Note this takes the earliest *stored* row, never the incoming habit's day.
            // Moving an origin backwards from a caller would invent scheduled occurrences
            // for days before the habit existed, and every one of them would be a miss.
            for extra in ordered.dropFirst() { modelContext.delete(extra) }
        } else {
            modelContext.insert(StoredHabit(habit))
        }
        try commit()
    }

    public func loadHabits() throws -> LoadResult<Habit> {
        let rows = try modelContext.fetch(FetchDescriptor<StoredHabit>())
        var values: [Habit] = []
        var skipped: [StoreMappingError] = []
        for row in rows {
            do { values.append(try row.toDomain()) }
            catch let error as StoreMappingError { skipped.append(error) }
        }
        // Sorted on the way out. A SwiftData fetch has no inherent order, and a routine whose
        // steps reshuffled between launches would be its own bug.
        values.sort { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }
        return LoadResult(values: values, skipped: skipped)
    }

    // MARK: - Completions

    /// Records an assertion about a day, collapsing it with anything already asserted.
    ///
    /// Returns the rows it could not read. Those are left in place rather than deleted: they
    /// are a bug in whatever wrote them, and destroying the evidence while the user is trying
    /// to tick a habit helps nobody. The write still goes through.
    @discardableResult
    public func record(_ event: CompletionEvent) throws -> [StoreMappingError] {
        let id = event.id
        let existing = try modelContext.fetch(
            FetchDescriptor<StoredCompletionEvent>(predicate: #Predicate { $0.eventID == id })
        )

        var assertions: [CompletionEvent] = [event]
        var readable: [StoredCompletionEvent] = []
        var skipped: [StoreMappingError] = []
        for row in existing {
            do {
                assertions.append(try row.toDomain())
                readable.append(row)
            } catch let error as StoreMappingError {
                skipped.append(error)
            }
        }

        // Every assertion shares one identifier, so exactly one survives the fold.
        guard let winner = assertions.resolved().first else { return skipped }

        if let row = readable.first {
            row.update(from: winner)
            for extra in readable.dropFirst() { modelContext.delete(extra) }
        } else {
            modelContext.insert(StoredCompletionEvent(winner))
        }

        try commit()
        return skipped
    }

    /// Records a completion only if nothing has ever been asserted about that day.
    ///
    /// This is the write an outside signal is allowed to make, and the restriction is the
    /// whole point of it. A bounded reconciliation on launch re-reads a trailing window of
    /// HealthKit, and a plain `record` would give the backfill a fresh `recordedAt` that beat
    /// the user's retraction — so a habit they explicitly un-ticked would tick itself again
    /// the next morning, repeatedly, with no way to make it stop.
    ///
    /// Guarding on "no assertion at all" rather than on "no completion" is deliberate: a
    /// retraction is an assertion, and it is precisely the one that must not be overridden.
    /// It also removes any need to remember which health samples have already been consumed,
    /// because event identifiers are content-addressed and re-reading the same day produces
    /// the identifier that is already there.
    ///
    /// Returns `true` if it wrote. `false` means the day already had an answer.
    @discardableResult
    public func propose(_ event: CompletionEvent) throws -> Bool {
        let id = event.id
        var descriptor = FetchDescriptor<StoredCompletionEvent>(predicate: #Predicate { $0.eventID == id })
        descriptor.fetchLimit = 1
        guard try modelContext.fetch(descriptor).isEmpty else { return false }

        // Recorded as signal-asserted whatever the caller passed. This is the proposal path
        // by definition, and the record should say so rather than trusting a parameter.
        let proposal = CompletionEvent(
            habitID: event.habitID, dayKey: event.dayKey, slotIndex: event.slotIndex,
            status: event.status, source: .automatic, occurredAt: event.occurredAt,
            recordedAt: event.recordedAt, timeZoneIdentifier: event.timeZoneIdentifier
        )
        modelContext.insert(StoredCompletionEvent(proposal))
        try commit()
        return true
    }

    /// Undoes a completion by appending a contrary assertion, never by deleting one.
    @discardableResult
    public func retract(
        habitID: UUID,
        dayKey: DayKey,
        slotIndex: Int = 0,
        at instant: Date,
        timeZoneIdentifier: String
    ) throws -> [StoreMappingError] {
        try record(
            CompletionEvent(
                habitID: habitID,
                dayKey: dayKey,
                slotIndex: slotIndex,
                status: .retracted,
                occurredAt: instant,
                recordedAt: instant,
                timeZoneIdentifier: timeZoneIdentifier
            )
        )
    }

    public func loadCompletionEvents(for habitID: UUID? = nil) throws -> LoadResult<CompletionEvent> {
        var descriptor = FetchDescriptor<StoredCompletionEvent>()
        if let habitID {
            descriptor.predicate = #Predicate { $0.habitID == habitID }
        }
        let rows = try modelContext.fetch(descriptor)

        var values: [CompletionEvent] = []
        var skipped: [StoreMappingError] = []
        for row in rows {
            do { values.append(try row.toDomain()) }
            catch let error as StoreMappingError { skipped.append(error) }
        }
        // Resolved on the way out, because a peer's duplicate can arrive after any write.
        return LoadResult(values: values.resolved(), skipped: skipped)
    }

    // MARK: - Lifecycle

    @discardableResult
    public func record(_ event: LifecycleEvent) throws -> [StoreMappingError] {
        let id = event.eventIdentifier
        let existing = try modelContext.fetch(
            FetchDescriptor<StoredLifecycleEvent>(predicate: #Predicate { $0.eventID == id })
        )

        var assertions: [LifecycleEvent] = [event]
        var readable: [StoredLifecycleEvent] = []
        var skipped: [StoreMappingError] = []
        for row in existing {
            do {
                assertions.append(try row.toDomain())
                readable.append(row)
            } catch let error as StoreMappingError {
                skipped.append(error)
            }
        }

        guard let winner = assertions.deduplicated().first else { return skipped }

        if let row = readable.first {
            row.update(from: winner)
            for extra in readable.dropFirst() { modelContext.delete(extra) }
        } else {
            modelContext.insert(StoredLifecycleEvent(winner))
        }

        try commit()
        return skipped
    }

    public func loadLifecycleEvents(for habitID: UUID? = nil) throws -> LoadResult<LifecycleEvent> {
        var descriptor = FetchDescriptor<StoredLifecycleEvent>()
        if let habitID {
            descriptor.predicate = #Predicate { $0.habitID == habitID }
        }
        let rows = try modelContext.fetch(descriptor)

        var values: [LifecycleEvent] = []
        var skipped: [StoreMappingError] = []
        for row in rows {
            do { values.append(try row.toDomain()) }
            catch let error as StoreMappingError { skipped.append(error) }
        }
        return LoadResult(values: values.deduplicated(), skipped: skipped)
    }

    // MARK: - Routine runs

    /// Inserts a run, or merges into the one already recorded for that routine and day.
    ///
    /// Steps are matched by their own content address and updated in place. A step absent
    /// from `run` is left alone rather than deleted, because absence far more often means
    /// "not reached yet", or "this device has not heard about it", than "removed".
    public func upsert(_ run: RoutineRun) throws {
        let id = run.id
        let existing = try modelContext.fetch(
            FetchDescriptor<StoredRoutineRun>(predicate: #Predicate { $0.runID == id })
        )

        let row: StoredRoutineRun
        if let first = existing.sorted(by: { $0.runID < $1.runID }).first ?? existing.first {
            first.update(from: run)
            // Re-parent before deleting, never after. The losing rows hold steps this one
            // has never seen, because each device writes the steps it witnessed, and the
            // relationship's `.cascade` rule takes them with the row. Deleting first lost a
            // whole device's worth of steps as a side effect, which contradicts the rule two
            // methods down that refuses to delete even one.
            for extra in existing where extra !== first {
                for step in extra.steps ?? [] { step.run = first }
                extra.steps = []
                modelContext.delete(extra)
            }
            row = first
        } else {
            row = StoredRoutineRun(
                runID: run.id,
                routineRaw: run.routine.rawValue,
                dayKeyRaw: run.dayKey.rawValue,
                startedAt: run.startedAt,
                endedAt: run.endedAt,
                timeZoneIdentifier: run.timeZoneIdentifier,
                steps: []
            )
            modelContext.insert(row)
        }

        // Adopt any step that arrived before its run. Without this it is unreachable
        // forever: `loadRoutineRuns()` walks runs, and a step with a nil `run` is on no
        // run's list. This is the same non-atomic-sync hazard that habits and events avoid
        // by not being related at all.
        let orphans = try modelContext.fetch(
            FetchDescriptor<StoredRoutineStep>(predicate: #Predicate { $0.runID == id && $0.run == nil })
        )
        for orphan in orphans { orphan.run = row }

        // Collapse duplicate step rows rather than merely ignoring them. Leaving the loser
        // in place returned the same habit twice from `toDomain()`, and `orderedSteps` then
        // sorted two elements its comparator calls equal, so their order was not stable.
        var byID: [String: StoredRoutineStep] = [:]
        for step in row.steps ?? [] {
            if let kept = byID[step.stepID] {
                // Keep whichever knows more. A nil clock is "not reached yet", so a row
                // carrying an end time is strictly better informed than one that is not.
                if kept.endedAt == nil, step.endedAt != nil { kept.update(from: step.toDomain()) }
                step.run = nil
                modelContext.delete(step)
            } else {
                byID[step.stepID] = step
            }
        }

        for step in run.steps {
            let stepID = StoredRoutineStep.stepID(runID: run.id, habitID: step.habitID)
            if let existingStep = byID[stepID] {
                existingStep.update(from: step)
            } else {
                let new = StoredRoutineStep(step, runID: run.id)
                new.run = row
                modelContext.insert(new)
                byID[stepID] = new
            }
        }

        try commit()
    }

    public func loadRoutineRuns() throws -> LoadResult<RoutineRun> {
        let rows = try modelContext.fetch(FetchDescriptor<StoredRoutineRun>())
        var values: [RoutineRun] = []
        var skipped: [StoreMappingError] = []
        for row in rows {
            do { values.append(try row.toDomain()) }
            catch let error as StoreMappingError { skipped.append(error) }
        }
        values.sort { $0.dayKey == $1.dayKey ? $0.id < $1.id : $0.dayKey < $1.dayKey }
        return LoadResult(values: values, skipped: skipped)
    }

    // MARK: - Health bindings

    /// Saves the binding for `binding.habitID`, replacing any other.
    ///
    /// A binding is configuration on this device, not a log, so replacing it is correct. It
    /// never syncs, which also means there is no peer whose duplicate could arrive later, but
    /// duplicates are still collapsed in case an earlier build left one.
    public func upsert(_ binding: HealthBinding) throws {
        let id = binding.habitID
        let existing = try modelContext.fetch(
            FetchDescriptor<StoredHealthBinding>(predicate: #Predicate { $0.habitID == id })
        )
        if let row = existing.first {
            row.update(from: binding)
            for extra in existing.dropFirst() { modelContext.delete(extra) }
        } else {
            modelContext.insert(StoredHealthBinding(binding))
        }
        try commit()
    }

    /// Unlinks a habit from Health. Its completions, including any Health proposed, stay.
    public func removeHealthBinding(for habitID: UUID) throws {
        let rows = try modelContext.fetch(
            FetchDescriptor<StoredHealthBinding>(predicate: #Predicate { $0.habitID == habitID })
        )
        for row in rows { modelContext.delete(row) }
        try commit()
    }

    public func loadHealthBindings() throws -> LoadResult<HealthBinding> {
        let rows = try modelContext.fetch(FetchDescriptor<StoredHealthBinding>())
        var values: [HealthBinding] = []
        var skipped: [StoreMappingError] = []
        for row in rows {
            do { values.append(try row.toDomain()) }
            catch let error as StoreMappingError { skipped.append(error) }
        }
        // One binding per habit, chosen the same way on every launch. The app keys bindings by
        // habit, and a second row for the same habit trapped that dictionary on every launch.
        // The furthest-reconciled row wins, so a duplicate can never send the backfill back
        // over days already covered; the rest of the order only has to be total.
        let unique = Dictionary(grouping: values, by: \.habitID).values.compactMap { group in
            group.max { lhs, rhs in
                if lhs.lastReconciledDay != rhs.lastReconciledDay {
                    return lhs.lastReconciledDay < rhs.lastReconciledDay
                }
                if lhs.signal != rhs.signal { return lhs.signal.rawValue < rhs.signal.rawValue }
                return (lhs.externalIdentifier ?? "") < (rhs.externalIdentifier ?? "")
            }
        }
        return LoadResult(
            values: unique.sorted { $0.habitID.uuidString < $1.habitID.uuidString },
            skipped: skipped
        )
    }

    /// Records that the backfill has covered `binding` through `day`.
    ///
    /// Updates only a row that still describes the same signal, and never inserts one. The
    /// backfill queries Health between reading the binding and writing this, and a plain
    /// upsert of the copy it read would bring back a binding the person had just removed, or
    /// overwrite the new one if they had relinked the habit to something else meanwhile.
    ///
    /// Also never moves backwards, so two overlapping backfills cannot undo each other.
    ///
    /// - Returns: whether a row was advanced.
    @discardableResult
    public func advanceReconciliation(of binding: HealthBinding, through day: DayKey) throws -> Bool {
        let id = binding.habitID
        let signal = binding.signal.rawValue
        let rows = try modelContext.fetch(
            FetchDescriptor<StoredHealthBinding>(predicate: #Predicate { $0.habitID == id })
        )
        var advanced = false
        for row in rows
        where row.signalRaw == signal
            && row.externalIdentifier == binding.externalIdentifier
            && row.lastReconciledDayRaw < day.rawValue {
            row.lastReconciledDayRaw = day.rawValue
            advanced = true
        }
        guard advanced else { return false }
        try commit()
        return true
    }

    // MARK: - The fold

    /// Every habit's logs folded into the shape scoring and the lock-in gate read from.
    ///
    /// This is the one read the app actually uses. Events are grouped by habit before the
    /// fold rather than handed to each history whole, which keeps it linear instead of
    /// quadratic on a path that runs inside a widget extension.
    public func loadHistories(today: DayKey) throws -> LoadResult<HabitHistory> {
        let habits = try loadHabits()
        let completions = try loadCompletionEvents()
        let lifecycle = try loadLifecycleEvents()

        let completionsByHabit = Dictionary(grouping: completions.values, by: \.habitID)
        let lifecycleByHabit = Dictionary(grouping: lifecycle.values, by: \.habitID)

        let histories = habits.values.map { habit in
            HabitHistory(
                habit: habit,
                events: completionsByHabit[habit.id] ?? [],
                lifecycle: lifecycleByHabit[habit.id] ?? [],
                today: today
            )
        }

        return LoadResult(
            values: histories,
            skipped: habits.skipped + completions.skipped + lifecycle.skipped
        )
    }
}

extension LifecycleEvent {
    /// `id` under a name a `#Predicate` can close over without ambiguity.
    fileprivate var eventIdentifier: String { id }
}
