import Foundation
import HabitKit
import Observation
import UserNotifications

/// When each routine's reminder fires, on this device.
///
/// Kept in `UserDefaults` rather than the synced store. It is a preference about this phone,
/// not a fact about a habit, and the watch will want its own. Putting it in the schema would
/// also freeze a field into CloudKit that no other device has any use for.
@Observable
final class ReminderSettings {
    @ObservationIgnored private let defaults: UserDefaults

    private var enabled: [RoutineSlot: Bool] = [:]
    private var times: [RoutineSlot: Int] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for routine in RoutineSlot.allCases {
            enabled[routine] = defaults.bool(forKey: Self.enabledKey(routine))
            times[routine] = defaults.object(forKey: Self.minutesKey(routine)) as? Int
                ?? (routine == .morning ? 7 * 60 : 21 * 60)
        }
    }

    func isEnabled(_ routine: RoutineSlot) -> Bool { enabled[routine] ?? false }

    func setEnabled(_ value: Bool, for routine: RoutineSlot) {
        enabled[routine] = value
        defaults.set(value, forKey: Self.enabledKey(routine))
    }

    /// Minutes after midnight, local time.
    func minutes(for routine: RoutineSlot) -> Int { times[routine] ?? 0 }

    func setMinutes(_ value: Int, for routine: RoutineSlot) {
        times[routine] = value
        defaults.set(value, forKey: Self.minutesKey(routine))
    }

    private static func enabledKey(_ routine: RoutineSlot) -> String { "reminder.\(routine.rawValue).enabled" }
    private static func minutesKey(_ routine: RoutineSlot) -> String { "reminder.\(routine.rawValue).minutes" }
}

/// Plans and replaces the pending routine reminders.
///
/// Every call replaces the whole plan. Planning is cheap and replacing is idempotent, so there
/// is no bookkeeping about which reminders already exist.
enum ReminderScheduler {
    static let identifierPrefix = "routine."
    nonisolated static let routineKey = RoutineSlot.notificationKey

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func reschedule(model: AppModel, settings: ReminderSettings, now: Date = .now) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        )

        let timeZone = model.timeZone
        for routine in RoutineSlot.allCases where settings.isEnabled(routine) {
            let histories = model.habits(in: routine)
            let days = ReminderPlan.days(
                for: routine,
                histories: histories,
                finishedToday: model.runsToday[routine]?.endedAt != nil
            )
            let minutes = settings.minutes(for: routine)

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone

            for day in days {
                // Wall-clock components, not midnight plus an offset. On a daylight-saving
                // day the offset lands an hour away from the time the person chose.
                let components = DateComponents(year: day.year, month: day.month, day: day.day,
                                                hour: minutes / 60, minute: minutes % 60)
                guard let fireDate = calendar.date(from: components), fireDate > now else { continue }

                let content = UNMutableNotificationContent()
                content.title = "\(routine.title) routine"
                content.body = body(for: histories, on: day)
                content.sound = .default
                content.userInfo = [routineKey: routine.rawValue]

                let request = UNNotificationRequest(
                    identifier: "\(identifierPrefix)\(routine.rawValue).\(day.rawValue)",
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                )
                try? await center.add(request)
            }
        }
    }

    /// Names the first habit, because the first step is the only one that needs deciding.
    private static func body(for histories: [HabitHistory], on day: DayKey) -> String {
        let due = histories.filter { $0.currentState == .active && $0.habit.isScheduled(on: day) }
        guard let first = due.first else { return "Time to start." }
        let rest = due.count - 1
        switch rest {
        case 0: return "Start with \(first.habit.title)."
        case 1: return "Start with \(first.habit.title), then one more."
        default: return "Start with \(first.habit.title), then \(rest) more."
        }
    }
}
