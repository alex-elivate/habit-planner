import Foundation
import HabitKit
import SwiftData
import Testing
@testable import HabitStore

private func t(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

/// A phone store with a little of everything the watch has to reproduce.
@MainActor
private func seededPhone() async throws -> (HabitStoreActor, ModelContainer, habitID: UUID) {
    let (store, container) = try makeStore()
    let habit = sampleHabit(schedule: .daysOfWeek([.monday, .tuesday, .thursday, .saturday]))
    let other = Habit(title: "Read", routine: .evening, order: 0, startedOn: referenceToday.advanced(by: -20))
    try await store.upsert(habit)
    try await store.upsert(other)

    for offset in 1...20 where offset % 3 != 0 {
        try await store.record(completion(habit.id, referenceToday.advanced(by: -offset),
                                          occurredAt: t(Double(offset) * 100)))
        try await store.record(completion(other.id, referenceToday.advanced(by: -offset),
                                          occurredAt: t(Double(offset) * 100 + 1)))
    }
    // A correction, which the watch must see as a correction and not as the tick it undoes.
    try await store.retract(habitID: habit.id, dayKey: referenceToday.advanced(by: -2),
                            at: t(10_000), timeZoneIdentifier: "UTC")
    try await store.record(LifecycleEvent(habitID: other.id, dayKey: referenceToday.advanced(by: -8),
                                          state: .paused, occurredAt: t(20_000), timeZoneIdentifier: "UTC"))
    try await store.record(LifecycleEvent(habitID: other.id, dayKey: referenceToday.advanced(by: -5),
                                          state: .active, occurredAt: t(20_500), timeZoneIdentifier: "UTC"))
    try await store.upsert(RoutineRun(
        routine: .morning, dayKey: referenceToday, startedAt: t(30_000), endedAt: nil,
        timeZoneIdentifier: "UTC",
        steps: [RoutineStep(habitID: habit.id, position: 0, startedAt: t(30_000), endedAt: t(30_060))]
    ))
    return (store, container, habit.id)
}

private func sortedHistories(_ store: HabitStoreActor) async throws -> [HabitHistory] {
    try await store.loadHistories(today: referenceToday).values.sorted { $0.habit.id.uuidString < $1.habit.id.uuidString }
}

@Suite("Watch bridge store")
struct BridgeStoreTests {

    // MARK: Snapshot into the watch

    @Test("A watch fed one snapshot folds to exactly what the phone folds to")
    @MainActor
    func snapshotReproducesPhone() async throws {
        let (phone, _, _) = try await seededPhone()
        let (watch, _) = try makeStore()

        let snapshot = try await phone.watchSnapshot(today: referenceToday, generatedAt: t(40_000))
        // Through bytes, as it travels.
        let received = try BridgeCodec.decodeSnapshot(try BridgeCodec.encode(snapshot))
        try await watch.merge(received)

        let phoneHistories = try await sortedHistories(phone)
        let watchHistories = try await sortedHistories(watch)
        #expect(phoneHistories.count == 2)
        #expect(watchHistories == phoneHistories)
        #expect(watchHistories.map(\.streak) == phoneHistories.map(\.streak))
        #expect(try await watch.loadRoutineRuns().values == phone.loadRoutineRuns().values)
    }

    @Test("Merging what the store already knows writes nothing")
    @MainActor
    func unchangedMergeWritesNothing() async throws {
        // On the phone a rewritten row is a CloudKit upload, and a watch report arrives after
        // every step carrying records the phone already has.
        let (phone, _, _) = try await seededPhone()
        let (watch, _) = try makeStore()
        let snapshot = try await phone.watchSnapshot(today: referenceToday, generatedAt: t(40_000))

        let first = try await watch.merge(snapshot)
        #expect(first.written > 0)
        #expect(try await watch.merge(snapshot).written == 0)
        // Into the store it came from, too.
        #expect(try await phone.merge(snapshot).written == 0)

        let report = try await watch.watchReport(from: referenceToday.advanced(by: -1))
        #expect(!report.completions.isEmpty)
        #expect(try await phone.merge(report).written == 0)
    }

    @Test("A snapshot never removes a record the watch made before it arrived")
    @MainActor
    func snapshotDoesNotRemoveLocalRecords() async throws {
        let (phone, _, habitID) = try await seededPhone()
        let (watch, _) = try makeStore()
        try await watch.merge(phone.watchSnapshot(today: referenceToday, generatedAt: t(40_000)))

        // Ticked on the watch while the phone was out of range.
        let ticked = completion(habitID, referenceToday, occurredAt: t(50_000))
        try await watch.record(ticked)
        // The phone's next snapshot was built before it heard about the tick.
        try await watch.merge(phone.watchSnapshot(today: referenceToday, generatedAt: t(50_100)))

        let today = try await watch.loadCompletionEvents(for: habitID).values.filter { $0.dayKey == referenceToday }
        #expect(today.count == 1)
        #expect(today.first?.status == .completed)
    }

    @Test("A late snapshot does not undo a newer retraction made on the watch")
    @MainActor
    func lateSnapshotKeepsNewerRetraction() async throws {
        let (phone, _, habitID) = try await seededPhone()
        let (watch, _) = try makeStore()
        let day = referenceToday.advanced(by: -1)
        let old = try await phone.watchSnapshot(today: referenceToday, generatedAt: t(40_000))
        try await watch.merge(old)

        try await watch.retract(habitID: habitID, dayKey: day, at: t(60_000), timeZoneIdentifier: "UTC")
        try await watch.merge(old)

        let event = try await watch.loadCompletionEvents(for: habitID).values.first { $0.dayKey == day }
        #expect(event?.status == .retracted)
    }

    @Test("A newer clock is stored even when the status it asserts has not changed")
    @MainActor
    func newerClockIsKeptWithSameStatus() async throws {
        // Done, undone and done again on the phone. The watch only ever sees "done" twice, but
        // the second carries the later clock, and a snapshot from between the two that arrives
        // late must lose to it. Skipping the write because the status matched would keep the
        // old clock and let that stale retraction win.
        let (watch, _) = try makeStore()
        let habitID = UUID()
        let day = referenceToday.advanced(by: -1)
        let done = completion(habitID, day, occurredAt: t(1_000), recordedAt: t(1_000))
        try await watch.record(done)

        let redone = completion(habitID, day, occurredAt: t(1_000), recordedAt: t(3_000))
        try await watch.merge(WatchSnapshot(generatedAt: t(3_100), habits: [], completions: [redone],
                                            lifecycle: [], runs: []))
        try await watch.merge(WatchSnapshot(generatedAt: t(2_100), habits: [],
                                            completions: [done.retracted(at: t(2_000))],
                                            lifecycle: [], runs: []))

        let event = try await watch.loadCompletionEvents(for: habitID).values.first
        #expect(event?.status == .completed)
        #expect(event?.recordedAt == t(3_000))
    }

    @Test("Two snapshots merged in either order leave the same store")
    @MainActor
    func snapshotOrderDoesNotMatter() async throws {
        let (phone, _, habitID) = try await seededPhone()
        let early = try await phone.watchSnapshot(today: referenceToday, generatedAt: t(40_000))
        try await phone.retract(habitID: habitID, dayKey: referenceToday.advanced(by: -1),
                                at: t(45_000), timeZoneIdentifier: "UTC")
        var renamed = try #require(try await phone.loadHabits().values.first { $0.id == habitID })
        renamed.title = "Walk the dog twice"
        try await phone.upsert(renamed)
        let late = try await phone.watchSnapshot(today: referenceToday, generatedAt: t(46_000))

        let (inOrder, _) = try makeStore()
        try await inOrder.merge(early)
        try await inOrder.merge(late)
        let (reversed, _) = try makeStore()
        try await reversed.merge(late)
        try await reversed.merge(early)

        let lhs = try await inOrder.loadCompletionEvents().values
        let rhs = try await reversed.loadCompletionEvents().values
        #expect(lhs.map(\.id) == rhs.map(\.id))
        #expect(lhs.map(\.status) == rhs.map(\.status))
        #expect(lhs.map(\.recordedAt) == rhs.map(\.recordedAt))
        // Habit definitions are the one thing a late snapshot can set back. They carry no
        // clock to merge on, and the next snapshot corrects them. What matters is that no
        // assertion about a day is lost either way.
        #expect(try await inOrder.loadHabits().values.first { $0.id == habitID }?.title == "Walk the dog twice")
    }

    @Test("Only today's and yesterday's runs go to the watch")
    @MainActor
    func snapshotRunsAreRecent() async throws {
        let (phone, _, habitID) = try await seededPhone()
        for offset in [1, 2, 5] {
            try await phone.upsert(RoutineRun(
                routine: .evening, dayKey: referenceToday.advanced(by: -offset), startedAt: t(1),
                endedAt: nil, timeZoneIdentifier: "UTC",
                steps: [RoutineStep(habitID: habitID, position: 0, startedAt: t(1))]
            ))
        }
        let snapshot = try await phone.watchSnapshot(today: referenceToday, generatedAt: t(40_000))
        #expect(Set(snapshot.runs.map(\.dayKey)) == [referenceToday, referenceToday.advanced(by: -1)])
    }

    @Test("Health bindings stay on the device")
    @MainActor
    func snapshotLeavesBindingsBehind() async throws {
        let (phone, _, habitID) = try await seededPhone()
        let drug = "base64-drug-identifier-that-must-not-travel"
        try await phone.upsert(HealthBinding(habitID: habitID, signal: .medication, externalIdentifier: drug,
                                             lastReconciledDay: referenceToday.advanced(by: -1)))

        let bytes = try BridgeCodec.encode(await phone.watchSnapshot(today: referenceToday, generatedAt: t(40_000)))
        #expect(String(decoding: bytes, as: UTF8.self).contains(drug) == false)

        let (watch, _) = try makeStore()
        try await watch.merge(BridgeCodec.decodeSnapshot(bytes))
        #expect(try await watch.loadHealthBindings().values.isEmpty)
    }

    // MARK: Report into the phone

    @Test("A routine run on the watch arrives on the phone")
    @MainActor
    func reportDeliversWatchWrites() async throws {
        let (phone, _, habitID) = try await seededPhone()
        let (watch, _) = try makeStore()
        try await watch.merge(phone.watchSnapshot(today: referenceToday, generatedAt: t(40_000)))

        try await watch.record(completion(habitID, referenceToday, occurredAt: t(50_000)))
        var run = try #require(try await watch.loadRoutineRuns().values.first { $0.dayKey == referenceToday })
        run.steps[0].endedAt = t(50_000)
        run.endedAt = t(50_000)
        try await watch.upsert(run)

        let report = try await watch.watchReport(from: referenceToday.advanced(by: -1))
        let result = try await phone.merge(BridgeCodec.decodeReport(try BridgeCodec.encode(report)))
        #expect(result.written == 2)

        let histories = try await phone.loadHistories(today: referenceToday).values
        #expect(histories.first { $0.habit.id == habitID }?.isCompletedToday == true)
        #expect(try await phone.loadRoutineRuns().values.first { $0.dayKey == referenceToday }?.endedAt == t(50_000))
    }

    @Test("A report carrying a tick the phone has since undone leaves it undone")
    @MainActor
    func reportDoesNotResurrectRetractedTick() async throws {
        let (phone, _, habitID) = try await seededPhone()
        let (watch, _) = try makeStore()
        try await watch.merge(phone.watchSnapshot(today: referenceToday, generatedAt: t(40_000)))
        try await watch.record(completion(habitID, referenceToday, occurredAt: t(50_000)))
        let report = try await watch.watchReport(from: referenceToday)

        try await phone.merge(report)
        try await phone.retract(habitID: habitID, dayKey: referenceToday, at: t(55_000), timeZoneIdentifier: "UTC")
        // The same report again, as a resend after the watch app relaunched.
        try await phone.merge(report)

        let histories = try await phone.loadHistories(today: referenceToday).values
        #expect(histories.first { $0.habit.id == habitID }?.isCompletedToday == false)
    }

    @Test("A report covers its window and nothing before it")
    @MainActor
    func reportWindow() async throws {
        let (phone, _, _) = try await seededPhone()
        let earliest = referenceToday.advanced(by: -4)
        let report = try await phone.watchReport(from: earliest)

        #expect(!report.completions.isEmpty)
        #expect(report.completions.allSatisfy { $0.dayKey >= earliest })
        let all = try await phone.loadCompletionEvents().values.filter { $0.dayKey >= earliest }
        #expect(report.completions.map(\.id) == all.map(\.id))
    }

    @Test("A stale run from the watch does not reopen a step the phone closed")
    @MainActor
    func staleRunReportDoesNotReopen() async throws {
        let (phone, _, habitID) = try await seededPhone()
        // Stale about the first step, and new about a second, so the merge has something to
        // write and the stale half has a chance to get in with it.
        let next = UUID()
        let stale = RoutineRun(
            routine: .morning, dayKey: referenceToday, startedAt: t(30_000), endedAt: nil,
            timeZoneIdentifier: "UTC",
            steps: [RoutineStep(habitID: habitID, position: 0, startedAt: t(30_000), endedAt: nil),
                    RoutineStep(habitID: next, position: 1, startedAt: t(30_060), endedAt: nil)]
        )
        let result = try await phone.merge(WatchReport(earliestDay: referenceToday, completions: [], runs: [stale]))

        #expect(result.written == 1)
        let run = try await phone.loadRoutineRuns().values.first { $0.dayKey == referenceToday }
        #expect(run?.steps.count == 2)
        #expect(run?.steps.first { $0.habitID == habitID }?.endedAt == t(30_060))

        // And a copy that adds nothing writes nothing.
        let stalest = RoutineRun(
            routine: .morning, dayKey: referenceToday, startedAt: t(30_000), endedAt: nil,
            timeZoneIdentifier: "UTC",
            steps: [RoutineStep(habitID: habitID, position: 0, startedAt: t(30_000), endedAt: nil)]
        )
        #expect(try await phone.merge(WatchReport(earliestDay: referenceToday, completions: [], runs: [stalest])).written == 0)
    }
}
