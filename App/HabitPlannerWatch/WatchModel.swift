import Foundation
import HabitKit
import HabitStore
import Observation
import WidgetKit

/// Everything the watch interface reads, folded fresh from the watch's own store.
///
/// The iPhone's `AppModel` without editing, gating or Health. The watch runs routines and
/// nothing else: habits are added and changed on the phone, where the lock-in gate is. Every
/// score and streak here is folded from the replica with the same HabitKit code the phone
/// uses, so the two agree whenever they hold the same records.
@Observable
final class WatchModel {
    let store: HabitStoreActor
    /// Whether the complication reads this store. Not the in-memory store, which it cannot see.
    let complicationsReadThisStore: Bool

    private(set) var today: DayKey
    private(set) var histories: [HabitHistory] = []
    private(set) var runsToday: [RoutineSlot: RoutineRun] = [:]
    /// Whether the replica has ever received a habit. Until it has, the watch explains itself
    /// rather than showing two empty routines.
    private(set) var hasHabits = false
    private(set) var planned: [RoutineSlot: PlannedHabit] = [:]
    /// Whether a record the lock-in gate reads could not be read. The watch never gates, but
    /// the complication shows the gate's progress and must not show it as open.
    private(set) var gateHasUnreadableInput = false

    /// The last write that failed, for the interface to show.
    var failure: String?

    /// Told the day of a write before it happens, and told again once it has. The bridge
    /// uses the first to widen its next report and the second to send it.
    @ObservationIgnored var beforeWrite: ((DayKey) -> Void)?
    @ObservationIgnored var afterWrite: (() -> Void)?

    init(store: HabitStoreActor, complicationsReadThisStore: Bool) {
        self.store = store
        self.complicationsReadThisStore = complicationsReadThisStore
        self.today = DayKey(.now, in: .current)
    }

    var timeZone: TimeZone { .current }

    func reload() async {
        today = DayKey(.now, in: timeZone)
        do {
            let loaded = try await store.loadHistories(today: today)
            let runs = try await store.loadRoutineRuns()
            let plans = try await store.loadPlannedHabits()
            histories = loaded.values
            planned = plans.values.resolved()
            gateHasUnreadableInput = loaded.skipped.contains(where: \.couldOpenGate)
            hasHabits = !loaded.values.isEmpty
            runsToday = Dictionary(
                runs.values.filter { $0.dayKey == today }.map { ($0.routine, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            refreshComplications()
        } catch {
            failure = "Could not read your habits. \(error.localizedDescription)"
        }
    }

    /// What the complications showed after the last reload. In memory only, to save reloads.
    @ObservationIgnored private var lastGlance: Glance?

    /// Asks the complications for a new timeline if anything they show has changed.
    ///
    /// The watch's reload budget is small, and a snapshot merge or a runner step reloads the
    /// model whether or not a complication would look any different.
    private func refreshComplications() {
        guard complicationsReadThisStore else { return }
        let glance = Glance(histories: histories, runs: runsToday, planned: planned,
                            gateHasUnreadableInput: gateHasUnreadableInput, at: .now, in: timeZone)
        guard glance != lastGlance else { return }
        lastGlance = glance
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetLink.glanceKind)
    }

    func history(for habitID: UUID) -> HabitHistory? {
        histories.first { $0.habit.id == habitID }
    }

    /// Habits still to run in `routine` today.
    func remaining(in routine: RoutineSlot) -> Int {
        RoutineRunner(routine: routine, histories: histories, resuming: runsToday[routine],
                      at: .now, in: timeZone).remaining.count
    }

    /// Habits in `routine` due today at all, done or not.
    func dueCount(in routine: RoutineSlot) -> Int {
        histories.filter { $0.habit.routine == routine && $0.isDueToday }.count
    }

    // MARK: - Writing

    /// Records an assertion. Returns whether it reached the store.
    @discardableResult
    func record(_ event: CompletionEvent) async -> Bool {
        await write(on: event.dayKey) { try await store.record(event) }
    }

    func save(_ run: RoutineRun) async {
        await write(on: run.dayKey) { try await store.upsert(run) }
    }

    @discardableResult
    private func write(on day: DayKey, _ body: () async throws -> Void) async -> Bool {
        beforeWrite?(day)
        var succeeded = true
        do {
            try await body()
        } catch {
            failure = error.localizedDescription
            succeeded = false
        }
        await reload()
        if succeeded { afterWrite?() }
        return succeeded
    }
}
