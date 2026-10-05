import Foundation
import HabitKit
import HabitStore
import UserNotifications

/// Done and Skip on a routine reminder, from the lock screen, without opening the app.
///
/// Each reminder names one habit and carries its identifier, and its buttons act on that
/// habit. After either, a quiet follow-up names the next habit with the same buttons, so a
/// routine can be worked through from the lock screen. The last one says the routine is done.
///
/// The app runs in the background for this, so the write is held open until iCloud has it,
/// as for the widget. A reminder from an earlier day does nothing, since its buttons would
/// write to a day that has settled.
@MainActor
final class ReminderActions {
    static let shared = ReminderActions()

    static let categoryIdentifier = "routine.step"
    nonisolated static let doneAction = "done"
    nonisolated static let skipAction = "skip"
    nonisolated static let habitKey = "habit"
    nonisolated static let dayKey = "day"
    private static let followUpPrefix = "followup."

    /// Set at launch. `nil` when the store could not be opened.
    var model: AppModel?
    var settings: ReminderSettings?

    /// The buttons, registered once at launch.
    static func registerCategory() {
        let done = UNNotificationAction(identifier: doneAction, title: "Done", icon: .init(systemImageName: "checkmark"))
        let skip = UNNotificationAction(identifier: skipAction, title: "Skip", icon: .init(systemImageName: "forward"))
        let category = UNNotificationCategory(identifier: categoryIdentifier, actions: [done, skip],
                                              intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Puts the buttons, and the habit they act on, onto a reminder.
    static func attach(habitID: UUID, day: DayKey, to content: UNMutableNotificationContent) {
        content.categoryIdentifier = categoryIdentifier
        content.userInfo[habitKey] = habitID.uuidString
        content.userInfo[dayKey] = day.rawValue
    }

    /// What a reminder carries, read out of its `userInfo` before it leaves the delegate, so
    /// only plain values cross to the main actor.
    struct Payload: Sendable {
        let routine: String?
        let habit: String?
        let day: Int?

        nonisolated init(_ userInfo: [AnyHashable: Any]) {
            routine = userInfo[RoutineSlot.notificationKey] as? String
            habit = userInfo[ReminderActions.habitKey] as? String
            day = userInfo[ReminderActions.dayKey] as? Int
        }
    }

    func handle(_ actionIdentifier: String, payload: Payload) async {
        guard let model, let routine = payload.routine.flatMap(RoutineSlot.init(rawValue:)) else { return }
        let action: ListAction = actionIdentifier == Self.doneAction ? .complete() : .skip
        let token = CloudUploadHold.shared.begin()
        var saved = false
        defer { CloudUploadHold.shared.finish(token, saved: saved) }
        await model.reload()

        // A reminder left on the lock screen overnight belongs to a day that has settled.
        // Said rather than done silently, since a button that does nothing reads as broken.
        if let day = payload.day, day != model.today.rawValue {
            await post(routine: routine,
                       body: "That reminder was for an earlier day, so nothing was changed. Open Habit Planner to see today.",
                       next: nil, replacing: false)
            return
        }

        // The habit the reminder named, and only that one. If it was done or skipped somewhere
        // else meanwhile, nothing is written: acting on whichever habit is next now would mark
        // done something nobody did. A reminder that names no habit acts on the next one.
        let states = model.states(in: routine)
        let fits: (StepState) -> Bool = { action == .skip ? $0.canSkip : $0.canComplete }
        let target: UUID
        if let named = payload.habit.flatMap(UUID.init(uuidString:)) {
            guard let state = states[named], let title = model.history(for: named)?.habit.title else {
                await postNext(routine: routine, after: "That habit is no longer in the routine.")
                return
            }
            guard fits(state) else {
                let already = switch state {
                case .done: "\(title) is already done."
                case .skipped: "\(title) was already skipped."
                default: "\(title) is not due today."
                }
                await postNext(routine: routine, after: already)
                return
            }
            target = named
        } else {
            guard let next = states.first(where: { $0.value == .next })?.key else {
                await postNext(routine: routine, after: "Nothing is left to do.")
                return
            }
            target = next
        }
        let title = model.history(for: target)?.habit.title ?? "That habit"

        let changed = await model.apply(action, to: target)
        saved = changed
        if !changed {
            let failed = model.failure != nil
            model.failure = nil
            await post(routine: routine,
                       body: failed ? "\(title) was not saved. Open Habit Planner to try again."
                                    : "Nothing changed for \(title). Open Habit Planner to check it.",
                       next: nil)
            return
        }
        await postNext(routine: routine, after: action == .skip ? "Skipped \(title)." : "Done: \(title).")
        if let settings { await ReminderScheduler.reschedule(model: model, settings: settings) }
    }

    /// Says `what`, then the habit next now with its buttons, or that the routine is finished.
    private func postNext(routine: RoutineSlot, after what: String) async {
        guard let model else { return }
        if let next = model.states(in: routine).first(where: { $0.value == .next })?.key,
           let nextTitle = model.history(for: next)?.habit.title {
            await post(routine: routine, body: "\(what) Next: \(nextTitle).", next: next)
        } else {
            await post(routine: routine, body: "\(what) That finishes your \(routine.title.lowercased()) routine.",
                       next: nil)
        }
    }

    /// Takes back delivered reminders that no longer fit: any from an earlier day, and ones
    /// whose buttons name a habit that has since been done or skipped. Run after every reload, so a
    /// reminder left on the lock screen does not offer to tick something already ticked.
    static func pruneDelivered(model: AppModel) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let stale = delivered.compactMap { notification -> String? in
            let content = notification.request.content
            let payload = Payload(content.userInfo)
            let ours = content.categoryIdentifier == categoryIdentifier
                || notification.request.identifier.hasPrefix(followUpPrefix)
            guard ours, let routine = payload.routine.flatMap(RoutineSlot.init(rawValue:)) else { return nil }
            // Any of ours from an earlier day, buttons or not.
            if let day = payload.day, day != model.today.rawValue { return notification.request.identifier }
            guard content.categoryIdentifier == categoryIdentifier else { return nil }
            guard let habit = payload.habit.flatMap(UUID.init(uuidString:)) else { return nil }
            let state = model.states(in: routine)[habit]
            return state?.canSkip == true ? nil : notification.request.identifier
        }
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
    }

    /// The follow-up. Silent, and replacing the routine's earlier ones, so a routine worked
    /// through here leaves one notification rather than a stack.
    ///
    /// Each has its own identifier, naming the habit it is for. Found in review: with one
    /// identifier per routine, a prune that read the delivered list just before this posted
    /// removed the new follow-up along with the old.
    ///
    /// `replacing` false leaves today's follow-up in place, for a note about an old reminder
    /// that should not take today's buttons away.
    private func post(routine: RoutineSlot, body: String, next: UUID?, replacing: Bool = true) async {
        guard let model else { return }
        let center = UNUserNotificationCenter.current()
        let prefix = "\(Self.followUpPrefix)\(routine.rawValue)."
        if replacing {
            let earlier = await center.deliveredNotifications().map(\.request.identifier).filter { $0.hasPrefix(prefix) }
            center.removeDeliveredNotifications(withIdentifiers: earlier)
        }

        let content = UNMutableNotificationContent()
        content.title = "\(routine.title) routine"
        content.body = body
        content.userInfo = [RoutineSlot.notificationKey: routine.rawValue, Self.dayKey: model.today.rawValue]
        if let next { Self.attach(habitID: next, day: model.today, to: content) }
        let request = UNNotificationRequest(
            identifier: "\(prefix)\(next?.uuidString ?? (replacing ? "none" : "note")).\(model.today.rawValue)",
            content: content, trigger: nil)
        try? await center.add(request)
    }
}
