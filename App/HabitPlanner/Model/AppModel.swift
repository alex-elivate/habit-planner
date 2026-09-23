import CoreData
import Foundation
import HabitKit
import HabitStore
import Observation

/// Everything the interface reads, folded fresh from the store.
///
/// Holds no state of its own that the store does not also hold. Every write goes to the store
/// first and the model reloads afterwards, so what is on screen is always what a fold of the
/// logs says, never an optimistic copy that could drift from it.
@Observable
final class AppModel {
    let store: HabitStoreActor
    let mode: StoreMode

    private(set) var today: DayKey
    private(set) var histories: [HabitHistory] = []
    private(set) var runsToday: [RoutineSlot: RoutineRun] = [:]
    private(set) var bindings: [UUID: HealthBinding] = [:]

    /// Records this build could not read. Shown in Settings rather than dropped silently, since
    /// a record written by a newer build is exactly the kind of failure nobody would notice.
    private(set) var unreadable: [StoreMappingError] = []

    /// The last write that failed, for the interface to show.
    var failure: String?

    private var remoteChanges: (any NSObjectProtocol)?

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

            histories = loaded.values
            runsToday = Dictionary(
                runs.values.filter { $0.dayKey == today }.map { ($0.routine, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            self.bindings = Dictionary(uniqueKeysWithValues: bindings.values.map { ($0.habitID, $0) })
            unreadable = loaded.skipped + runs.skipped + bindings.skipped
        } catch {
            failure = "Could not read your habits. \(error.localizedDescription)"
        }
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

    /// Whether a new habit may join `routine`, with the assessment behind a refusal.
    func gate(for routine: RoutineSlot) -> (decision: LockInGate.Decision, judged: LockInGate.Assessment?) {
        let decision = LockInGate.canAddHabit(to: routine, histories: histories)
        guard case .blocked = decision else { return (decision, nil) }
        // The same selection the gate makes, so the progress shown is the habit actually judged.
        let judged = histories
            .filter { $0.habit.routine == routine && $0.currentState == .active }
            .max { lhs, rhs in
                if lhs.habit.startedOn != rhs.habit.startedOn { return lhs.habit.startedOn < rhs.habit.startedOn }
                return lhs.habit.id.uuidString < rhs.habit.id.uuidString
            }
            .map(LockInGate.assess)
        return (decision, judged)
    }

    /// Whether `routine` has anything left to run today.
    func hasWorkRemaining(in routine: RoutineSlot) -> Bool {
        RoutineRunner(routine: routine, histories: histories, resuming: runsToday[routine],
                      at: .now, in: timeZone).isFinished == false
    }

    // MARK: - Completions

    /// Ticks or un-ticks today from the list. Un-ticking appends a retraction.
    func toggleToday(_ habitID: UUID) async {
        guard let history = history(for: habitID), history.isDueToday else { return }
        await write {
            if history.isCompletedToday {
                try await store.retract(habitID: habitID, dayKey: today, at: .now,
                                        timeZoneIdentifier: timeZone.identifier)
            } else {
                try await store.record(CompletionEvent(habitID: habitID, at: .now, in: timeZone))
            }
        }
    }

    func record(_ event: CompletionEvent) async {
        await write { try await store.record(event) }
    }

    func save(_ run: RoutineRun) async {
        await write { try await store.upsert(run) }
    }

    // MARK: - Habits

    enum AddHabitError: LocalizedError {
        case gateClosed
        var errorDescription: String? { "This routine's newest habit has not bedded in yet." }
    }

    /// Adds a habit to the end of its routine, if the lock-in gate allows it.
    ///
    /// Checked here as well as in the interface, because the button's state was computed from
    /// a fold that may be a sync behind.
    func add(_ draft: HabitDraft) async throws {
        await reload()
        guard LockInGate.canAddHabit(to: draft.routine, histories: histories).isOpen else {
            throw AddHabitError.gateClosed
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
        await write { try await store.upsert(habit) }
    }

    func update(_ habitID: UUID, from draft: HabitDraft) async {
        guard var habit = history(for: habitID)?.habit else { return }
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

    func setState(_ state: LifecycleEvent.State, for habitID: UUID) async {
        await write {
            try await store.record(LifecycleEvent(habitID: habitID, state: state, at: .now, in: timeZone))
        }
    }

    // MARK: - Health bindings

    func link(_ habitID: UUID, signal: HealthSignal, externalIdentifier: String?) async {
        guard var habit = history(for: habitID)?.habit else { return }
        habit.completionSource = .automatic
        let binding = HealthBinding(habitID: habitID, signal: signal,
                                    externalIdentifier: externalIdentifier, lastReconciledDay: today)
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

    /// Fills settled days the app was never opened, from Health.
    ///
    /// Everything goes through `propose`, which refuses any day that already carries an
    /// assertion, so a day somebody un-ticked stays un-ticked.
    func reconcileHealth(using health: HealthService) async {
        guard health.isAvailable else { return }
        for binding in bindings.values {
            guard let days = HealthBackfill.daysToReconcile(binding, today: today),
                  let history = history(for: binding.habitID) else { continue }
            let interval = DateInterval(start: days.lowerBound.start(in: timeZone),
                                        end: days.upperBound.advanced(by: 1).start(in: timeZone))
            do {
                let instants = try await health.signalInstants(for: binding, in: interval)
                let proposals = HealthBackfill.proposals(for: history, in: days, signalInstants: instants,
                                                         recordedAt: .now, timeZone: timeZone)
                var caughtUp = binding
                caughtUp.lastReconciledDay = days.upperBound
                for proposal in proposals { try await store.propose(proposal) }
                try await store.upsert(caughtUp)
            } catch {
                // Not advanced, so the same days are tried again next launch. Health being
                // unreachable is not evidence that nothing happened.
                continue
            }
        }
        await reload()
    }

    // MARK: - Developer

    func primeCloudKitSchema() async throws -> [String] {
        try await store.primeCloudKitSchema()
    }

    // MARK: -

    private func write(_ body: () async throws -> Void) async {
        do {
            try await body()
        } catch {
            failure = error.localizedDescription
        }
        await reload()
    }
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

extension RoutineSlot {
    var title: String {
        switch self {
        case .morning: "Morning"
        case .evening: "Evening"
        }
    }

    var symbol: String {
        switch self {
        case .morning: "sunrise"
        case .evening: "moon.stars"
        }
    }
}
