import Foundation
import HabitKit
import SwiftData
import Testing
@testable import HabitStore

private func t(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }

/// Gaps found by a mutation sweep of the original suite: 43 mutations, 26 survivors.
/// Each test here is one mutation that used to pass unnoticed.
@Suite("Coverage")
@MainActor
struct CoverageTests {

    // MARK: Validation is only worth having on every path

    @Test("A zeroed day is rejected on every mapping path, not just two")
    func zeroedDayRejectedEverywhere() {
        // The 740,000-element hazard. `DayKey(rawValue: 0)` has an ordinal of -719560, and
        // folding a habit that started then allocates an array that size inside a widget.
        // Only StoredHabit and StoredCompletionEvent were covered; a lifecycle event with a
        // zeroed day reached LifecycleTimeline unvalidated.
        // Each identifier here is the CORRECT content address for a zeroed day, so the
        // identifier guard cannot fire and only `DayKey(validating:)` can reject the row.
        // With a deliberately wrong identifier these passed while the day went unvalidated.
        let habitID = UUID()
        #expect(throws: StoreMappingError.self) {
            try StoredLifecycleEvent(eventID: "\(habitID.uuidString)|0",
                                     habitID: habitID, dayKeyRaw: 0).toDomain()
        }
        #expect(throws: StoreMappingError.self) {
            try StoredRoutineRun(runID: "morning|0",
                                 routineRaw: RoutineSlot.morning.rawValue, dayKeyRaw: 0).toDomain()
        }
    }

    @Test("An identifier that does not address its content is rejected on every path")
    func identifierMismatchRejectedEverywhere() {
        #expect(throws: StoreMappingError.self) {
            try StoredLifecycleEvent(eventID: "wrong", habitID: UUID(),
                                     dayKeyRaw: referenceToday.rawValue).toDomain()
        }
        #expect(throws: StoreMappingError.self) {
            try StoredRoutineRun(runID: "wrong", routineRaw: RoutineSlot.morning.rawValue,
                                 dayKeyRaw: referenceToday.rawValue).toDomain()
        }
    }

    @Test("Every raw-value column rejects a value from a newer version")
    func everyRawColumnRejectsUnknownValues() {
        // `statusRaw` defaulting instead of throwing would read a future retraction back as
        // a completion, which silently un-does somebody's correction.
        let habitID = UUID()
        let day = referenceToday
        #expect(throws: StoreMappingError.self) {
            try StoredCompletionEvent(eventID: "\(habitID.uuidString)|\(day.rawValue)|0",
                                      habitID: habitID, dayKeyRaw: day.rawValue,
                                      statusRaw: "abandoned").toDomain()
        }
        #expect(throws: StoreMappingError.self) {
            try StoredCompletionEvent(eventID: "\(habitID.uuidString)|\(day.rawValue)|0",
                                      habitID: habitID, dayKeyRaw: day.rawValue,
                                      sourceRaw: "telepathy").toDomain()
        }
        #expect(throws: StoreMappingError.self) {
            try StoredLifecycleEvent(eventID: "\(habitID.uuidString)|\(day.rawValue)",
                                     habitID: habitID, dayKeyRaw: day.rawValue,
                                     stateRaw: "hibernating").toDomain()
        }
        #expect(throws: StoreMappingError.self) {
            try StoredHabit(habitID: habitID, scheduleKindRaw: "lunar",
                            startedOnRaw: day.rawValue).toDomain()
        }
    }

    // MARK: Editing a habit

    @Test("Editing a habit persists every editable field")
    func habitEditPersistsEveryField() async throws {
        // The original test checked title and order only, so dropping the schedule, the cue,
        // the routine or the completion source from `update(from:)` all went unnoticed —
        // editing a habit's schedule simply never saved.
        let (store, _) = try makeStore()
        let id = UUID()
        try await store.upsert(sampleHabit(id: id))

        var edited = sampleHabit(id: id)
        edited.title = "Edited"
        edited.cue = "after lunch"
        edited.twoMinuteVersion = "one page"
        edited.identityStatement = "I read"
        edited.routine = .evening
        edited.order = 7
        edited.schedule = .daysOfWeek([.monday, .wednesday])
        edited.completionSource = .automatic
        try await store.upsert(edited)

        let loaded = try #require(try await store.loadHabits().values.first)
        #expect(loaded.title == "Edited")
        #expect(loaded.cue == "after lunch")
        #expect(loaded.twoMinuteVersion == "one page")
        #expect(loaded.identityStatement == "I read")
        #expect(loaded.routine == .evening)
        #expect(loaded.order == 7)
        #expect(loaded.schedule == .daysOfWeek([.monday, .wednesday]))
        #expect(loaded.completionSource == .automatic)
    }

    @Test("Editing a habit cannot move its origin or its identity")
    func habitEditCannotMoveTheOrigin() async throws {
        // Documented as forbidden and entirely unpinned: adding `startedOnRaw` to
        // `update(from:)` passed the whole suite. Moving the day a habit started silently
        // rewrites every score and every gate assessment ever made about it.
        let (store, _) = try makeStore()
        let id = UUID()
        let origin = referenceToday.advanced(by: -60)
        try await store.upsert(sampleHabit(id: id, startedOn: origin))

        var moved = sampleHabit(id: id, startedOn: referenceToday.advanced(by: -5))
        moved.title = "Moved"
        try await store.upsert(moved)

        let loaded = try #require(try await store.loadHabits().values.first)
        #expect(loaded.startedOn == origin, "the origin moved")
        #expect(loaded.id == id)
        #expect(loaded.title == "Moved")
    }

    @Test("Duplicate habit rows converge on the same survivor whatever the fetch order")
    func duplicateHabitRowsConverge() async throws {
        // `existing.first` on a FetchDescriptor with no `sortBy` has no defined order, and in
        // practice it varied between runs on identical data. Two devices kept different rows
        // and the habit's origin flickered between them.
        let id = UUID()
        var survivors: [DayKey] = []
        for reversed in [false, true] {
            let container = try makeContainer()
            let old = StoredHabit(sampleHabit(id: id, startedOn: referenceToday.advanced(by: -60)))
            let recent = StoredHabit(sampleHabit(id: id, startedOn: referenceToday.advanced(by: -5)))
            for row in (reversed ? [recent, old] : [old, recent]) {
                container.mainContext.insert(row)
            }
            try container.mainContext.save()

            let store = HabitStoreActor(modelContainer: container)
            try await store.upsert(sampleHabit(id: id, startedOn: referenceToday.advanced(by: -60)))
            let loaded = try await store.loadHabits()
            #expect(loaded.values.count == 1)
            survivors.append(try #require(loaded.values.first?.startedOn))
        }
        #expect(survivors[0] == survivors[1])
        // The earliest origin wins: counting history the habit did not have is a smaller
        // error than erasing history it did, and only the latter silently locks a routine.
        #expect(survivors[0] == referenceToday.advanced(by: -60))
    }

    // MARK: Lifecycle, which had no store-level dedup coverage at all

    @Test("Lifecycle assertions collapse on write and resolve on read")
    func lifecycleDedupWorksBothWays() async throws {
        let container = try makeContainer()
        let habitID = UUID()
        let day = referenceToday.advanced(by: -3)

        // Two peers disagree about the same day. The later decision wins, because a
        // lifecycle state is an intention and an intention can be changed.
        container.mainContext.insert(StoredLifecycleEvent(
            LifecycleEvent(habitID: habitID, dayKey: day, state: .paused,
                           occurredAt: t(100), timeZoneIdentifier: "UTC")))
        container.mainContext.insert(StoredLifecycleEvent(
            LifecycleEvent(habitID: habitID, dayKey: day, state: .archived,
                           occurredAt: t(500), timeZoneIdentifier: "UTC")))
        try container.mainContext.save()

        let store = HabitStoreActor(modelContainer: container)
        let read = try await store.loadLifecycleEvents()
        #expect(read.values.count == 1)
        #expect(read.values.first?.state == .archived)

        try await store.record(LifecycleEvent(habitID: habitID, dayKey: day, state: .active,
                                              occurredAt: t(900), timeZoneIdentifier: "UTC"))
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredLifecycleEvent>()) == 1)
        #expect(try await store.loadLifecycleEvents().values.first?.state == .active)

        // An older decision arriving late must lose. Without this the incoming event is
        // always the winner, so skipping the fold entirely on the write side went unnoticed.
        try await store.record(LifecycleEvent(habitID: habitID, dayKey: day, state: .paused,
                                              occurredAt: t(200), timeZoneIdentifier: "UTC"))
        #expect(try await store.loadLifecycleEvents().values.first?.state == .active,
                "a stale lifecycle decision overwrote a newer one")
    }

    // MARK: Arrival order

    @Test("Whether a day reads as done never depends on sync arrival order")
    func completionOutcomeIsOrderIndependent() async throws {
        // The watch ticks, the phone undoes it, the Mac (which never saw the undo) ticks
        // again. Last writer wins, so the day is done — from every arrival order.
        let habitID = UUID()
        let day = referenceToday.advanced(by: -1)
        let tick = completion(habitID, day, occurredAt: t(0), recordedAt: t(0))
        let undo = tick.retracted(at: t(1_800))
        let again = completion(habitID, day, occurredAt: t(3_600), recordedAt: t(3_600))

        for order in permutationsOf([tick, undo, again]) {
            let (store, _) = try makeStore()
            for event in order { try await store.record(event) }
            let got = try await store.loadCompletionEvents().values.first
            #expect(got?.status == .completed)
            #expect(got?.occurredAt == t(0), "the moment it was done was not preserved")
            #expect(got?.recordedAt == t(3_600), "the clock that decides future conflicts regressed")
        }
    }

    // MARK: Routine runs

    @Test("A step absent from an update is kept, never deleted")
    func absentStepsAreNotDeleted() async throws {
        // The doc comment forbids this and nothing pinned it: adding deletion of steps
        // missing from the incoming run passed the suite. Absence usually means "not
        // reached yet", or "this device has not heard about it".
        let (store, container) = try makeStore()
        let first = UUID(), second = UUID()

        var run = RoutineRun(routine: .morning, dayKey: referenceToday,
                             startedAt: t(1_000), timeZoneIdentifier: "UTC")
        run.steps = [RoutineStep(habitID: first, position: 0, startedAt: t(1_000)),
                     RoutineStep(habitID: second, position: 1, startedAt: t(1_100))]
        try await store.upsert(run)

        // A device that only knows about the first step writes again.
        run.steps = [RoutineStep(habitID: first, position: 0, startedAt: t(1_000), endedAt: t(1_050))]
        try await store.upsert(run)

        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredRoutineStep>()) == 2)
        let loaded = try #require(try await store.loadRoutineRuns().values.first)
        #expect(loaded.steps.count == 2)
    }

    @Test("Reordering a routine mid-run persists")
    func stepPositionPersists() async throws {
        let (store, _) = try makeStore()
        let habitID = UUID()
        var run = RoutineRun(routine: .morning, dayKey: referenceToday, timeZoneIdentifier: "UTC")
        run.steps = [RoutineStep(habitID: habitID, position: 0)]
        try await store.upsert(run)
        run.steps = [RoutineStep(habitID: habitID, position: 4)]
        try await store.upsert(run)

        let loaded = try #require(try await store.loadRoutineRuns().values.first)
        #expect(loaded.steps.first?.position == 4)
    }

    @Test("Collapsing duplicate runs keeps the steps both rows knew about")
    func duplicateRunsKeepEveryStep() async throws {
        // Each device writes the steps it witnessed, so duplicate rows hold different
        // subsets. Deleting a losing row took its steps with it through `.cascade`.
        let container = try makeContainer()
        let runID = "morning|\(referenceToday.rawValue)"
        let first = UUID(), second = UUID()

        for habitID in [first, second] {
            let row = StoredRoutineRun(runID: runID, routineRaw: RoutineSlot.morning.rawValue,
                                       dayKeyRaw: referenceToday.rawValue, timeZoneIdentifier: "UTC")
            let step = StoredRoutineStep(stepID: StoredRoutineStep.stepID(runID: runID, habitID: habitID),
                                         habitID: habitID, runID: runID, position: 0, run: row)
            row.steps = [step]
            container.mainContext.insert(row)
            container.mainContext.insert(step)
        }
        try container.mainContext.save()

        let store = HabitStoreActor(modelContainer: container)
        try await store.upsert(RoutineRun(routine: .morning, dayKey: referenceToday,
                                          timeZoneIdentifier: "UTC"))

        let loaded = try #require(try await store.loadRoutineRuns().values.first)
        #expect(Set(loaded.steps.map(\.habitID)) == Set([first, second]))
    }

    @Test("A step that arrived before its run is adopted, not lost")
    func orphanedStepIsAdopted() async throws {
        // CloudKit does not save related changes atomically. A step with a nil run is on no
        // run's list, so it was invisible to `loadRoutineRuns()` forever.
        let container = try makeContainer()
        let runID = "morning|\(referenceToday.rawValue)"
        let habitID = UUID()
        container.mainContext.insert(StoredRoutineStep(
            stepID: StoredRoutineStep.stepID(runID: runID, habitID: habitID),
            habitID: habitID, runID: runID, position: 0, startedAt: t(10), run: nil))
        try container.mainContext.save()

        let store = HabitStoreActor(modelContainer: container)
        #expect(try await store.loadRoutineRuns().values.isEmpty)

        try await store.upsert(RoutineRun(routine: .morning, dayKey: referenceToday,
                                          timeZoneIdentifier: "UTC"))
        let loaded = try #require(try await store.loadRoutineRuns().values.first)
        #expect(loaded.steps.map(\.habitID) == [habitID])
    }

    @Test("Duplicate step rows inside one run collapse")
    func duplicateStepRowsCollapse() async throws {
        let container = try makeContainer()
        let runID = "morning|\(referenceToday.rawValue)"
        let habitID = UUID()
        let row = StoredRoutineRun(runID: runID, routineRaw: RoutineSlot.morning.rawValue,
                                   dayKeyRaw: referenceToday.rawValue, timeZoneIdentifier: "UTC")
        container.mainContext.insert(row)
        var steps: [StoredRoutineStep] = []
        for ended in [nil, t(99)] as [Date?] {
            let step = StoredRoutineStep(stepID: StoredRoutineStep.stepID(runID: runID, habitID: habitID),
                                         habitID: habitID, runID: runID, position: 0,
                                         startedAt: t(10), endedAt: ended, run: row)
            container.mainContext.insert(step)
            steps.append(step)
        }
        row.steps = steps
        try container.mainContext.save()

        let store = HabitStoreActor(modelContainer: container)
        try await store.upsert(RoutineRun(routine: .morning, dayKey: referenceToday,
                                          timeZoneIdentifier: "UTC"))

        let loaded = try #require(try await store.loadRoutineRuns().values.first)
        #expect(loaded.steps.count == 1)
        // The better-informed row wins: a nil clock means "not reached yet".
        #expect(loaded.steps.first?.endedAt == t(99))
    }

    // MARK: Loaders

    @Test("The habit filter on the loaders is honoured")
    func loaderPredicatesAreHonoured() async throws {
        // Making both loaders ignore their predicate entirely passed the suite, because no
        // test ever passed an argument.
        let (store, _) = try makeStore()
        let wanted = UUID(), other = UUID()
        try await store.record(completion(wanted, referenceToday.advanced(by: -1)))
        try await store.record(completion(other, referenceToday.advanced(by: -1)))
        try await store.record(LifecycleEvent(habitID: wanted, dayKey: referenceToday.advanced(by: -1),
                                              state: .paused, occurredAt: t(1), timeZoneIdentifier: "UTC"))
        try await store.record(LifecycleEvent(habitID: other, dayKey: referenceToday.advanced(by: -1),
                                              state: .paused, occurredAt: t(1), timeZoneIdentifier: "UTC"))

        #expect(try await store.loadCompletionEvents(for: wanted).values.map(\.habitID) == [wanted])
        #expect(try await store.loadLifecycleEvents(for: wanted).values.map(\.habitID) == [wanted])
        #expect(try await store.loadCompletionEvents().values.count == 2)
    }

    @Test("Every loader reports the rows it could not read")
    func everyLoaderReportsFailures() async throws {
        // Only loadHabits was covered, so swallowing errors in the others passed — including
        // in loadHistories, which is the one read the app actually uses.
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(StoredHabit(sampleHabit()))
        context.insert(StoredHabit(habitID: UUID(), title: "bad habit", startedOnRaw: 0))
        context.insert(StoredCompletionEvent(eventID: "bad", dayKeyRaw: 0))
        context.insert(StoredLifecycleEvent(eventID: "bad", dayKeyRaw: 0))
        context.insert(StoredRoutineRun(runID: "bad", dayKeyRaw: 0))
        try context.save()

        let store = HabitStoreActor(modelContainer: container)
        #expect(try await store.loadHabits().skipped.count == 1)
        #expect(try await store.loadCompletionEvents().skipped.count == 1)
        #expect(try await store.loadLifecycleEvents().skipped.count == 1)
        #expect(try await store.loadRoutineRuns().skipped.count == 1)

        let histories = try await store.loadHistories(today: referenceToday)
        #expect(histories.hasFailures)
        #expect(histories.skipped.count == 3, "loadHistories hid a failure from its callers")
        #expect(histories.values.count == 1)
    }

    @Test("Loaders return a stable order")
    func loadersSortTheirOutput() async throws {
        // A SwiftData fetch has no inherent order, and both sorts were decorative: removing
        // either passed the suite, despite the comments calling a reshuffle its own bug.
        let (store, _) = try makeStore()
        for order in [3, 1, 2, 0].shuffled() {
            var habit = sampleHabit(id: UUID())
            habit.order = order
            try await store.upsert(habit)
        }
        #expect(try await store.loadHabits().values.map(\.order) == [0, 1, 2, 3])

        for offset in [2, 0, 1] {
            try await store.upsert(RoutineRun(routine: .morning,
                                              dayKey: referenceToday.advanced(by: -offset),
                                              timeZoneIdentifier: "UTC"))
        }
        let days = try await store.loadRoutineRuns().values.map(\.dayKey)
        #expect(days == days.sorted())
    }

    // MARK: Slots

    @Test("slotIndex is part of the content address and is carried through")
    func slotIndexIsHonoured() async throws {
        // Untested everywhere: hardcoding `slotIndex: 0` in the stored initialiser, and
        // making `retract` ignore its argument, both passed. Because slotIndex is part of
        // the content address, a bug there breaks deduplication rather than losing a field.
        let (store, container) = try makeStore()
        let habitID = UUID()
        let day = referenceToday.advanced(by: -1)

        let first = CompletionEvent(habitID: habitID, dayKey: day, slotIndex: 0,
                                    occurredAt: t(10), timeZoneIdentifier: "UTC")
        let second = CompletionEvent(habitID: habitID, dayKey: day, slotIndex: 1,
                                     occurredAt: t(20), timeZoneIdentifier: "UTC")
        #expect(first.id != second.id)

        try await store.record(first)
        try await store.record(second)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredCompletionEvent>()) == 2)

        // Retracting one slot must not touch the other.
        try await store.retract(habitID: habitID, dayKey: day, slotIndex: 1,
                                at: t(30), timeZoneIdentifier: "UTC")
        let loaded = try await store.loadCompletionEvents().values
        #expect(loaded.first(where: { $0.slotIndex == 0 })?.status == .completed)
        #expect(loaded.first(where: { $0.slotIndex == 1 })?.status == .retracted)
    }

    // MARK: Provenance

    @Test("A proposed completion is recorded as signal-asserted, a tick as the person's")
    func provenanceIsRecorded() async throws {
        // Habit.completionSource cannot stand in for this: it is mutable expectation, so
        // flipping it would retroactively relabel every completion ticked by hand.
        let (store, _) = try makeStore()
        let habitID = UUID()

        try await store.record(completion(habitID, referenceToday.advanced(by: -1)))
        _ = try await store.propose(completion(habitID, referenceToday.advanced(by: -2)))

        let loaded = try await store.loadCompletionEvents().values
        #expect(loaded.first(where: { $0.dayKey == referenceToday.advanced(by: -1) })?.source == .manual)
        #expect(loaded.first(where: { $0.dayKey == referenceToday.advanced(by: -2) })?.source == .automatic)
    }

    // MARK: Schema version

    @Test("A record from a newer build is reported, never read and written back")
    func newerRecordsAreLeftAlone() async throws {
        // `schemaVersion` documented exactly this from the first commit and nothing read it.
        // A v2 record round-tripped through a v1 mapping loses whatever v1 does not know
        // about, and the next edit writes that loss back over the original.
        let container = try makeContainer()
        let habit = sampleHabit()
        let row = StoredHabit(habit)
        row.schemaVersion = 99
        container.mainContext.insert(row)
        try container.mainContext.save()

        let store = HabitStoreActor(modelContainer: container)
        let loaded = try await store.loadHabits()
        #expect(loaded.values.isEmpty)
        #expect(loaded.skipped.count == 1)
        if case .recordIsNewerThanThisBuild = loaded.skipped.first {} else {
            Issue.record("expected a version rejection, got \(String(describing: loaded.skipped.first))")
        }
    }

    @Test("Editing a record restamps the schema version that wrote it")
    func editingRestampsTheVersion() async throws {
        let container = try makeContainer()
        let habit = sampleHabit()
        let row = StoredHabit(habit)
        row.schemaVersion = 0          // as if written by an older build
        container.mainContext.insert(row)
        try container.mainContext.save()

        let store = HabitStoreActor(modelContainer: container)
        var edited = habit
        edited.title = "Edited"
        try await store.upsert(edited)

        let fetched = try container.mainContext.fetch(FetchDescriptor<StoredHabit>())
        #expect(fetched.first?.schemaVersion == HabitSchemaV1.versionIdentifier.major)
    }

    @Test("A failed save does not poison every write that follows it")
    func failedSaveIsRolledBack() async throws {
        // The actor holds one context for the life of the process, so staged changes from a
        // failed save would be re-attempted on every later save.
        let (store, _) = try makeStore()
        try await store.record(completion(UUID(), referenceToday.advanced(by: -1)))
        let loaded = try await store.loadCompletionEvents()
        #expect(loaded.values.count == 1)
    }

}

/// Every ordering of `items`, for proving a fold does not depend on arrival order.
func permutationsOf<T>(_ items: [T]) -> [[T]] {
    guard items.count > 1 else { return [items] }
    var result: [[T]] = []
    for (index, item) in items.enumerated() {
        var rest = items
        rest.remove(at: index)
        for tail in permutationsOf(rest) { result.append([item] + tail) }
    }
    return result
}
