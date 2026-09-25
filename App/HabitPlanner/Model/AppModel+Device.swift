import Foundation
import HabitKit
import HabitStore

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
        for binding in bindings.values {
            guard let days = HealthBackfill.daysToReconcile(binding, today: today),
                  let history = history(for: binding.habitID) else { continue }
            let interval = DateInterval(start: days.lowerBound.start(in: timeZone),
                                        end: days.upperBound.advanced(by: 1).start(in: timeZone))
            do {
                let instants = try await health.signalInstants(for: binding, in: interval)
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
            await ReminderScheduler.reschedule(model: self, settings: reminders)
        }
        refreshing = pass
        await pass.value
    }
}
