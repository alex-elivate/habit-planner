import Foundation
import HabitKit
import HabitStore
import UIKit

/// The parts of the model only the iPhone has: Health, and the reminders it schedules.
///
/// Kept out of `AppModel` so the Mac shares the model without either platform needing an
/// `#if`. macOS has no HealthKit to read, and the phone's reminders reach the Mac anyway.
extension AppModel {

    /// Fills settled days the app was never opened, from Health.
    ///
    /// Everything goes through `propose`, which refuses any day that already carries an
    /// assertion, so a day somebody un-ticked stays un-ticked.
    func reconcileHealth(using health: HealthService) async {
        guard health.isAvailable else { return }
        let shared = sharedReadings
        for binding in bindings.values {
            guard let days = HealthBackfill.daysToReconcile(binding, today: today),
                  let history = history(for: binding.habitID) else { continue }
            let interval = DateInterval(start: days.lowerBound.start(in: timeZone),
                                        end: days.upperBound.advanced(by: 1).start(in: timeZone))
            do {
                // One dose linked in both routines counts in one of them. See `HealthMatching`.
                let instants = HealthMatching.instants(
                    try await health.signalInstants(for: binding, in: interval),
                    for: history.habit.routine,
                    signal: binding.signal,
                    sharedAcrossRoutines: (shared[HealthMatching.key(binding)]?.count ?? 0) > 1,
                    in: timeZone)
                let proposals = HealthBackfill.proposals(for: history, in: days, signalInstants: instants,
                                                         recordedAt: .now, timeZone: timeZone)
                for proposal in proposals { try await store.propose(proposal) }
                // Not an upsert of the copy read before the query. The person may have
                // unlinked or relinked the habit while Health was answering.
                try await store.advanceReconciliation(of: binding, through: days.upperBound)
            } catch {
                // Not advanced, so the same days are tried again next launch. Health being
                // unreachable is not evidence that nothing happened.
                continue
            }
        }
        await reload()
    }

    /// The routines each Health reading is linked in, for `HealthMatching`.
    var sharedReadings: [String: Set<RoutineSlot>] {
        // Archived habits are left out: a link nobody uses must not split anyone's doses.
        HealthMatching.routines(linking: bindings.values,
                                habits: Dictionary(histories.filter { $0.currentState != .archived }
                                                       .map { ($0.habit.id, $0.habit.routine) },
                                                   uniquingKeysWith: { first, _ in first }))
    }

    /// Counts today's linked habits that Health shows as done, and offers to undo it.
    ///
    /// Only habits nobody has had a say on today: `propose` refuses a day that carries any
    /// assertion, so Not done, or undoing this, stays as the person left it. Counted at the
    /// time Health shows, so the record says when it happened. Done when the app opens or
    /// comes back to the screen, which is when the person can see the undo bar.
    func countFromHealth(using health: HealthService) async {
        guard health.isAvailable else { return }
        let shared = sharedReadings
        let interval = DateInterval(start: today.start(in: timeZone), end: .now)
        // An offer made by a swipe while Health was answering is the person's own, and stays.
        let offerBefore = undoOffer?.id
        var steps: [UndoOffer.Step] = []
        var titles: [String] = []
        for binding in bindings.values.sorted(by: { $0.habitID.uuidString < $1.habitID.uuidString }) {
            guard let history = history(for: binding.habitID), history.currentState == .active,
                  history.isDueToday, !history.isCompletedToday,
                  let found = try? await health.signalInstants(for: binding, in: interval) else { continue }
            let routine = history.habit.routine
            let mine = HealthMatching.instants(found, for: routine, signal: binding.signal,
                                               sharedAcrossRoutines: (shared[HealthMatching.key(binding)]?.count ?? 0) > 1,
                                               in: timeZone)
            guard let first = mine.min(), let before = states(in: routine)[binding.habitID] else { continue }
            guard await apply(.propose(occurredAt: first), to: binding.habitID),
                  let after = states(in: routine)[binding.habitID] else { continue }
            steps.append(.init(habitID: binding.habitID,
                               inverse: Self.undo(for: .propose(occurredAt: first), from: before,
                                                  undoing: nil, title: "").inverse,
                               leftAs: after))
            titles.append(history.habit.title)
        }
        guard !steps.isEmpty, undoOffer?.id == offerBefore else { return }
        let duration = max(8, Self.undoDuration(voiceOver: UIAccessibility.isVoiceOverRunning))
        undoOffer = UndoOffer(message: "Counted from Health: \(titles.formatted(.list(type: .and)))",
                              steps: steps, day: today, duration: duration)
    }

    /// Reload, backfill from Health, and replan reminders, one pass at a time.
    ///
    /// Launch and becoming active both ask for this at once. Run side by side, each reminder
    /// pass read the pending list, cleared it and added its own plan, and a plan built from
    /// older data could add back a reminder the newer one had dropped. Each pass now waits
    /// for the one before it.
    func refresh(health: HealthService, reminders: ReminderSettings) async {
        let previous = refreshing
        let pass = Task {
            await previous?.value
            await reload()
            await reconcileHealth(using: health)
            await countFromHealth(using: health)
            await ReminderScheduler.reschedule(model: self, settings: reminders)
        }
        refreshing = pass
        await pass.value
    }
}
