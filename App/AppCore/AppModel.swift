import CoreData
import Foundation
import HabitKit
import HabitStore
import Observation
import WidgetKit

/// Everything the interface reads, folded fresh from the store.
///
/// Holds no state of its own that the store does not also hold. Every write goes to the store
/// first and the model reloads afterwards, so what is on screen is always what a fold of the
/// logs says, never an optimistic copy that could drift from it.
@Observable
final class AppModel: RoutineActing {
    let store: HabitStoreActor
    let mode: StoreMode

    private(set) var today: DayKey
    private(set) var histories: [HabitHistory] = []
    private(set) var runsToday: [RoutineSlot: RoutineRun] = [:]
    private(set) var bindings: [UUID: HealthBinding] = [:]
    /// The habit each routine plans to add next. Cleared plans are kept, see `PlannedHabit`.
    private(set) var planned: [RoutineSlot: PlannedHabit] = [:]

    /// Records this build could not read. Shown in Settings rather than dropped silently, since
    /// a record written by a newer build is exactly the kind of failure nobody would notice.
    private(set) var unreadable: [StoreMappingError] = []

    /// The last write that failed, for the interface to show.
    var failure: String?

    private var remoteChanges: (any NSObjectProtocol)?

    /// Runs after every successful reload, which follows every write and every change CloudKit
    /// delivers. The watch bridge sends a snapshot from here.
    @ObservationIgnored var afterReload: (() -> Void)?

    init(store: HabitStoreActor, mode: StoreMode) {
        self.store = store
        self.mode = mode
        self.today = DayKey(.now, in: .current)
    }

    var timeZone: TimeZone { .current }

    // MARK: - Reading

    func reload() async {
        today = DayKey(.now, in: timeZone)
        do {
            let loaded = try await store.loadHistories(today: today)
            let runs = try await store.loadRoutineRuns()
            let bindings = try await store.loadHealthBindings()
            let plans = try await store.loadPlannedHabits()

            histories = loaded.values
            runsToday = Dictionary(
                runs.values.filter { $0.dayKey == today }.map { ($0.routine, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            // The store already returns one binding per habit. Not trapping here anyway, since
            // a duplicate key would otherwise crash every launch.
            self.bindings = Dictionary(bindings.values.map { ($0.habitID, $0) },
                                       uniquingKeysWith: { first, _ in first })
            planned = plans.values.resolved()
            unreadable = loaded.skipped + runs.skipped + bindings.skipped + plans.skipped
            refreshWidgets()
            afterReload?()
        } catch {
            failure = "Could not read your habits. \(error.localizedDescription)"
        }
    }

    // MARK: - Widgets

    /// What the widgets showed after the last reload, to tell whether they need another.
    ///
    /// Held in memory only. It exists to save a reload, not to be read by anything, and a
    /// fresh launch simply reloads once.
    @ObservationIgnored private var lastGlance: Glance?

    /// Asks the widgets for a new timeline if anything they show has changed.
    ///
    /// A reload follows every write and every CloudKit delivery, and most change nothing a
    /// widget shows. Reloads the app asks for while in the background count against a daily
    /// budget, so they are spent only when the fold says the widget is out of date.
    private func refreshWidgets() {
        // Widgets read the syncing store in the App Group. The debug stores are elsewhere.
        guard mode.syncs else { return }
        let glance = Glance(histories: histories, runs: runsToday, planned: planned,
                            gateHasUnreadableInput: gateHasUnreadableInput, at: .now, in: timeZone)
        guard glance != lastGlance else { return }
        lastGlance = glance
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetLink.glanceKind)
    }

    /// Reloads whenever CloudKit delivers changes from another device.
    func observeRemoteChanges() {
        guard remoteChanges == nil else { return }
        remoteChanges = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
    }

    /// Habits in `routine` that are not archived, in sequence order.
    func habits(in routine: RoutineSlot) -> [HabitHistory] {
        histories
            .filter { $0.habit.routine == routine && $0.currentState != .archived }
            .sorted { lhs, rhs in
                if lhs.habit.order != rhs.habit.order { return lhs.habit.order < rhs.habit.order }
                return lhs.habit.id.uuidString < rhs.habit.id.uuidString
            }
    }

    var archived: [HabitHistory] {
        histories.filter { $0.currentState == .archived }.sorted { $0.habit.title < $1.habit.title }
    }

    func history(for habitID: UUID) -> HabitHistory? {
        histories.first { $0.habit.id == habitID }
    }

    /// Whether a new habit may join `routine`, and why not.
    enum Gate {
        case open
        case blocked(LockInGate.Assessment)
        /// A record the gate depends on could not be read, so no answer is trustworthy.
        case unreadable

        var isOpen: Bool {
            if case .open = self { return true }
            return false
        }
    }

    /// Records whose absence could open the gate. Their routine cannot be known without
    /// reading them, so any one of them holds every routine shut.
    var gateHasUnreadableInput: Bool { unreadable.contains(where: \.couldOpenGate) }

    /// Decided by `RoutineGlance.Unlock`, the same rule the widgets show, so the two can never
    /// disagree about whether a routine is open.
    func gate(for routine: RoutineSlot) -> Gate {
        switch RoutineGlance.Unlock(routine: routine, histories: histories,
                                    gateHasUnreadableInput: gateHasUnreadableInput) {
        case .open: .open
        case .unavailable: .unreadable
        case .beddingIn(_, let assessment): .blocked(assessment)
        }
    }

    /// Whether `routine` has anything left to run today.
    func hasWorkRemaining(in routine: RoutineSlot) -> Bool {
        RoutineRunner(routine: routine, histories: histories, resuming: runsToday[routine],
                      at: .now, in: timeZone).isFinished == false
    }

    // MARK: - Completions

    /// Ticks or un-ticks the day the row shows. Un-ticking appends a retraction.
    ///
    /// Both directions write to the day the row was folded for, not to a day worked out from
    /// the clock. In the minutes between midnight and the next reload the two differ, and a
    /// tick landing on a different day from the un-tick beside it would be a correction that
    /// corrects nothing.
    func toggleToday(_ habitID: UUID) async {
        guard let history = history(for: habitID), history.isDueToday else { return }
        let day = history.today
        let now = Date.now
        await write {
            if history.isCompletedToday {
                try await store.retract(habitID: habitID, dayKey: day, at: now,
                                        timeZoneIdentifier: timeZone.identifier)
            } else {
                try await store.record(CompletionEvent(habitID: habitID, dayKey: day, occurredAt: now,
                                                       timeZoneIdentifier: timeZone.identifier))
            }
        }
    }

    /// Records an assertion. Returns whether it reached the store.
    @discardableResult
    func record(_ event: CompletionEvent) async -> Bool {
        await write { try await store.record(event) }
    }

    func save(_ run: RoutineRun) async {
        await write { try await store.upsert(run) }
    }

    // MARK: - Habits

    enum AddHabitError: LocalizedError {
        case gateClosed
        case unreadable
        case restoreGated
        case scheduleWouldOpenGate

        var errorDescription: String? {
            switch self {
            case .gateClosed: "This routine's newest habit has not bedded in yet."
            case .unreadable: "Some habits were saved by a newer version of the app. Update this device to add habits."
            case .restoreGated: "Restoring works like adding a habit. It can come back once the routine's newest habit beds in."
            case .scheduleWouldOpenGate: "This change would count past misses as rest days and unlock the routine early. Change it once this habit has bedded in."
            }
        }
    }

    /// Adds a habit to the end of its routine, if the lock-in gate allows it.
    ///
    /// Checked here as well as in the interface, because the button's state was computed from
    /// a fold that may be a sync behind.
    func add(_ draft: HabitDraft) async throws {
        await reload()
        guard gate(for: draft.routine).isOpen else {
            throw gateHasUnreadableInput ? AddHabitError.unreadable : AddHabitError.gateClosed
        }
        let nextOrder = (habits(in: draft.routine).map(\.habit.order).max() ?? -1) + 1
        let habit = Habit(
            title: draft.title.nilIfBlank ?? draft.title,
            cue: draft.cue.nilIfBlank,
            twoMinuteVersion: draft.twoMinuteVersion.nilIfBlank,
            identityStatement: draft.identityStatement.nilIfBlank,
            routine: draft.routine,
            order: nextOrder,
            schedule: draft.schedule,
            startedOn: today
        )
        let added = await write { try await store.upsert(habit) }
        // The plan is used up once the habit it named exists. A different habit added in its
        // place leaves the plan standing for the next time the routine unlocks.
        if added, let plan = planned.active(for: draft.routine),
           plan.title.localizedCaseInsensitiveCompare(habit.title) == .orderedSame {
            await clearPlan(for: draft.routine)
        }
    }

    // MARK: - Intents

    /// Marks done the habit next in `routine`, for Siri, Shortcuts and the widget's button.
    ///
    /// Throws rather than setting `failure`, so Siri can say what went wrong instead of an
    /// alert waiting in an app nobody opened.
    func completeCurrentStep(in routine: RoutineSlot) async throws -> StepOutcome {
        let outcome = try await store.completeCurrentStep(in: routine, at: .now, timeZone: timeZone)
        // The same reload every write ends with, so the list, the widgets and the watch
        // snapshot all follow.
        await reload()
        return outcome
    }

    func glanceNow() async throws -> Glance {
        try await store.glance(at: .now, in: timeZone)
    }

    // MARK: - Planned habits

    /// Plans the habit `routine` adds next. A blank title clears the plan.
    func plan(_ title: String, for routine: RoutineSlot) async {
        await write { try await store.record(PlannedHabit(routine: routine, title: title, recordedAt: .now)) }
    }

    func clearPlan(for routine: RoutineSlot) async {
        await write { try await store.record(PlannedHabit.cleared(routine, at: .now)) }
    }

    func update(_ habitID: UUID, from draft: HabitDraft) async throws {
        guard var habit = history(for: habitID)?.habit else { return }
        // A schedule change re-judges every past day. Refused where that would open the gate.
        if draft.schedule != habit.schedule {
            guard !gateHasUnreadableInput,
                  LockInGate.allowsScheduleChange(of: habitID, to: draft.schedule, histories: histories)
            else { throw AddHabitError.scheduleWouldOpenGate }
        }
        habit.title = draft.title.nilIfBlank ?? draft.title
        habit.cue = draft.cue.nilIfBlank
        habit.twoMinuteVersion = draft.twoMinuteVersion.nilIfBlank
        habit.identityStatement = draft.identityStatement.nilIfBlank
        habit.schedule = draft.schedule
        await write { try await store.upsert(habit) }
    }

    /// Rewrites display positions after a drag. Safe because nothing keys on `order`.
    func move(in routine: RoutineSlot, from source: IndexSet, to destination: Int) async {
        var ordered = habits(in: routine).map(\.habit)
        ordered.move(fromOffsets: source, toOffset: destination)
        await write {
            for (position, var habit) in ordered.enumerated() where habit.order != position {
                habit.order = position
                try await store.upsert(habit)
            }
        }
    }

    /// Whether an archived habit may come back now. Restoring is gated like adding.
    func canRestore(_ habitID: UUID) -> Bool {
        guard !gateHasUnreadableInput, let history = history(for: habitID) else { return false }
        return LockInGate.canRestore(history, histories: histories)
    }

    func setState(_ state: LifecycleEvent.State, for habitID: UUID) async {
        if state != .archived, history(for: habitID)?.currentState == .archived, !canRestore(habitID) {
            failure = AddHabitError.restoreGated.localizedDescription
            return
        }
        await write {
            try await store.record(LifecycleEvent(habitID: habitID, state: state, at: .now, in: timeZone))
        }
    }

    // MARK: - Health bindings

    func link(_ habitID: UUID, signal: HealthSignal, externalIdentifier: String?) async {
        guard var habit = history(for: habitID)?.habit else { return }
        habit.completionSource = .automatic
        // Reconciled through yesterday, so the link day itself is covered once it settles. A
        // walk the morning the habit was linked is still that habit's walk, and starting at
        // today would lose it for good if the runner was not opened that day.
        let binding = HealthBinding(habitID: habitID, signal: signal,
                                    externalIdentifier: externalIdentifier,
                                    lastReconciledDay: today.advanced(by: -1))
        await write {
            try await store.upsert(binding)
            try await store.upsert(habit)
        }
    }

    func unlink(_ habitID: UUID) async {
        guard var habit = history(for: habitID)?.habit else { return }
        habit.completionSource = .manual
        await write {
            try await store.removeHealthBinding(for: habitID)
            try await store.upsert(habit)
        }
    }

    // MARK: - Developer

    func primeCloudKitSchema() async throws -> [String] {
        try await store.primeCloudKitSchema()
    }

    // MARK: -

    /// Runs a write, reports a failure, and reloads either way. Returns whether it succeeded.
    @discardableResult
    private func write(_ body: () async throws -> Void) async -> Bool {
        var succeeded = true
        do {
            try await body()
        } catch {
            failure = error.localizedDescription
            succeeded = false
        }
        await reload()
        return succeeded
    }

    // MARK: - Refresh

    /// The pass in progress, so the next waits for it. See the iPhone app's `refresh`.
    @ObservationIgnored var refreshing: Task<Void, Never>?
}

/// The editable fields of a habit, before it exists or while it is being changed.
struct HabitDraft: Equatable {
    var title = ""
    var cue = ""
    var twoMinuteVersion = ""
    var identityStatement = ""
    var routine: RoutineSlot = .morning
    var schedule: Schedule = .daily

    init(routine: RoutineSlot = .morning) {
        self.routine = routine
    }

    init(_ habit: Habit) {
        title = habit.title
        cue = habit.cue ?? ""
        twoMinuteVersion = habit.twoMinuteVersion ?? ""
        identityStatement = habit.identityStatement ?? ""
        routine = habit.routine
        schedule = habit.schedule
    }

    var isValid: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if case .daysOfWeek(let days) = schedule { return !days.isEmpty }
        return true
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
