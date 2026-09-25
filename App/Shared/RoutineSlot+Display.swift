import HabitKit

extension RoutineSlot: @retroactive Identifiable {
    public var id: String { rawValue }
}

nonisolated extension RoutineSlot {
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

    /// The `userInfo` key a reminder carries its routine under.
    ///
    /// Shared because the iPhone schedules the reminder and the watch receives it too. A
    /// reminder the phone schedules is forwarded to the watch when the phone is locked, and
    /// tapping it there opens the watch app with the same payload.
    nonisolated static let notificationKey = "routine"
}
