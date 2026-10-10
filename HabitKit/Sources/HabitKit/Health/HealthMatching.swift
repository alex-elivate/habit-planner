import Foundation

/// Which of Health's readings belong to which habit, when more than one habit is linked to
/// the same thing.
///
/// Somebody who takes one medication morning and evening links it to a habit in each routine.
/// Counted as it is, one dose would tick both. So when a reading is linked in both routines,
/// a morning habit takes the readings before noon and an evening habit the ones from noon on.
///
/// A workout linked in only one routine counts there at any time, since a morning walk taken
/// late is still that habit's walk. A medication's evening habit takes only readings from
/// noon on even when the drug is linked nowhere else: a twice-daily drug linked only to the
/// evening would otherwise be ticked by the morning dose. A dose taken after 12:00 for the
/// morning goes to the evening, which is the limit of splitting on the clock.
public enum HealthMatching {
    /// What two bindings share when they read the same thing from Health.
    public static func key(_ binding: HealthBinding) -> String {
        "\(binding.signal.rawValue)|\(binding.externalIdentifier ?? "")"
    }

    /// The routines each reading is linked in, keyed by `key(_:)`, for `instants(_:for:signal:sharedAcrossRoutines:in:)`.
    public static func routines(
        linking bindings: some Sequence<HealthBinding>,
        habits: [UUID: RoutineSlot]
    ) -> [String: Set<RoutineSlot>] {
        var routines: [String: Set<RoutineSlot>] = [:]
        for binding in bindings {
            guard let routine = habits[binding.habitID] else { continue }
            routines[key(binding), default: []].insert(routine)
        }
        return routines
    }

    /// The readings that belong to a habit in `routine`, in their original order.
    public static func instants(
        _ instants: some Sequence<Date>,
        for routine: RoutineSlot,
        signal: HealthSignal,
        sharedAcrossRoutines: Bool,
        in timeZone: TimeZone
    ) -> [Date] {
        let split = sharedAcrossRoutines || (signal == .medication && routine == .evening)
        guard split else { return Array(instants) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return instants.filter { instant in
            let morning = calendar.component(.hour, from: instant) < 12
            return morning == (routine == .morning)
        }
    }
}
