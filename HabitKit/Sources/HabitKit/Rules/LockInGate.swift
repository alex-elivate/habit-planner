import Foundation

/// Decides when a habit has bedded in far enough to earn the right to add another.
///
/// The gate counts *scheduled occurrences*, not calendar days. Habits form through
/// repetition rather than the passage of time, so a three-times-a-week habit is judged on
/// the same terms as a daily one. Left to run, this lands somewhere in the four-to-ten week
/// range, which is where the evidence actually sits: Lally et al. (2010) found a mean near
/// 66 days across a range of 18 to 254. The familiar 21-day figure traces back to Maxwell
/// Maltz's observations of plastic surgery patients and describes nothing about habits.
public enum LockInGate {
    /// Scheduled occurrences that must have elapsed before the gate will even look.
    public static let requiredOccurrences = 28

    /// Completion rate demanded across those occurrences.
    public static let requiredRate = 0.85

    /// How far back a pair of consecutive misses still counts against you.
    public static let doubleMissWindowDays = 14

    public enum Decision: Hashable, Sendable {
        case open
        case blocked(Blocker)

        public var isOpen: Bool { self == .open }
    }

    public enum Blocker: Hashable, Sendable {
        case notEnoughHistory(elapsed: Int, required: Int)
        case rateTooLow(rate: Double, required: Double)
        case recentDoubleMiss(secondMissOn: DayKey)
    }

    /// Everything the interface needs to show how close a habit is, not just whether it passed.
    public struct Assessment: Hashable, Sendable {
        public let habitID: UUID
        public let elapsedOccurrences: Int
        public let requiredOccurrences: Int
        public let rate: Double?
        public let requiredRate: Double
        public let recentDoubleMiss: DayKey?
        public let decision: Decision

        public var isLockedIn: Bool { decision.isOpen }

        /// How far along the repetition requirement is, 0 through 1.
        public var repetitionProgress: Double {
            guard requiredOccurrences > 0 else { return 1 }
            return min(1, Double(elapsedOccurrences) / Double(requiredOccurrences))
        }
    }

    /// Judges a single habit.
    public static func assess(_ history: HabitHistory) -> Assessment {
        let occurrences = history.settledOccurrences
        let window = occurrences.suffix(requiredOccurrences)
        let rate: Double? = window.isEmpty
            ? nil
            : Double(window.count(where: \.isCompleted)) / Double(window.count)

        let doubleMiss = firstDoubleMiss(
            in: history.settledOccurrences,
            secondMissOnOrAfter: history.today.advanced(by: -doubleMissWindowDays)
        )

        let decision: Decision
        if occurrences.count < requiredOccurrences {
            decision = .blocked(.notEnoughHistory(
                elapsed: occurrences.count,
                required: requiredOccurrences
            ))
        } else if let doubleMiss {
            decision = .blocked(.recentDoubleMiss(secondMissOn: doubleMiss))
        } else if let rate, rate < requiredRate {
            decision = .blocked(.rateTooLow(rate: rate, required: requiredRate))
        } else {
            decision = .open
        }

        return Assessment(
            habitID: history.habit.id,
            elapsedOccurrences: occurrences.count,
            requiredOccurrences: requiredOccurrences,
            rate: rate,
            requiredRate: requiredRate,
            recentDoubleMiss: doubleMiss,
            decision: decision
        )
    }

    /// Whether a new habit may be added to `routine`.
    ///
    /// Only the habit that most recently joined the routine is examined. Older habits have
    /// already earned their place, and re-judging them would mean one rough week
    /// retroactively locking a routine the person built months ago.
    ///
    /// A **paused** habit is still examined. Pausing is not a way past the gate: if pausing
    /// the newest habit released it, the person could add another, resume the first, and have
    /// two habits bedding in at once. A paused habit that has not bedded in therefore holds
    /// the routine until it is resumed and beds in, or is archived.
    ///
    /// An **archived** habit is out of the routine and never examined. Restoring one is
    /// adding it back, so it joins the routine on the day of the restore and becomes the habit
    /// judged next. See `canRestore(_:histories:)` for when that is allowed.
    public static func canAddHabit(
        to routine: RoutineSlot,
        histories: some Sequence<HabitHistory>
    ) -> Decision {
        guard let newest = judged(in: routine, histories: histories) else {
            return .open  // The first habit in an empty routine is never gated.
        }
        return assess(newest).decision
    }

    /// The habit `canAddHabit` judges for `routine`, or `nil` if the routine is empty.
    public static func judged(
        in routine: RoutineSlot,
        histories: some Sequence<HabitHistory>
    ) -> HabitHistory? {
        let candidates = histories.filter {
            $0.habit.routine == routine && $0.currentState != .archived
        }
        // Ties break on the identifier, never on `order`. Display position is mutable, so
        // tiebreaking on it meant dragging a row could change which habit was judged and
        // open an irreversible gate. Falling back on sequence order instead would have made
        // the answer depend on an unordered SwiftData fetch.
        return candidates.max { lhs, rhs in
            let left = lhs.lifecycle.joinedRoutine(asOf: lhs.today)
            let right = rhs.lifecycle.joinedRoutine(asOf: rhs.today)
            if left != right { return left < right }
            return lhs.habit.id.uuidString < rhs.habit.id.uuidString
        }
    }

    /// Whether an archived habit may be restored to its routine.
    ///
    /// Restoring is adding a habit back, so it passes the same gate as adding one: allowed
    /// when a new habit could be added, or when the habit being restored had already bedded
    /// in before it was archived. Without this, archiving a habit that had not bedded in,
    /// adding another, and restoring the first would leave two bedding in at once.
    public static func canRestore(
        _ habit: HabitHistory,
        histories: some Sequence<HabitHistory>
    ) -> Bool {
        let others = histories.filter { $0.habit.id != habit.habit.id }
        return canAddHabit(to: habit.habit.routine, histories: others).isOpen || assess(habit).isLockedIn
    }

    /// Whether changing a habit to `schedule` may be saved.
    ///
    /// A schedule change re-judges every past day against the new schedule, because nothing
    /// derived is stored. Missed Tuesdays stop being misses once the habit is only due on
    /// Mondays. Allowed freely except where it would open a gate that is currently shut:
    /// then it would be a way of editing a habit into having bedded in.
    public static func allowsScheduleChange(
        of habitID: UUID,
        to schedule: Schedule,
        histories: some Sequence<HabitHistory>
    ) -> Bool {
        let all = Array(histories)
        guard let current = all.first(where: { $0.habit.id == habitID }) else { return true }
        let routine = current.habit.routine
        guard !canAddHabit(to: routine, histories: all).isOpen else { return true }

        var changed = current.habit
        changed.schedule = schedule
        let proposed = all.map { $0.habit.id == habitID ? $0.replacing(changed) : $0 }
        return !canAddHabit(to: routine, histories: proposed).isOpen
    }

    /// The day of the second miss in the first consecutive pair landing inside the window.
    ///
    /// The scan runs over the whole history rather than a pre-sliced window, because misses
    /// are adjacent as *occurrences* while the window is measured in *days*. Slicing first
    /// blinded it to any pair straddling the boundary, which made the window 13 days rather
    /// than 14 for a daily habit. For a three-times-a-week habit the gap between consecutive
    /// sessions is two or three days, so the same slice hid a genuine double-miss entirely.
    private static func firstDoubleMiss(
        in occurrences: [ScheduledOccurrence],
        secondMissOnOrAfter earliest: DayKey
    ) -> DayKey? {
        var previousWasMiss = false
        for occurrence in occurrences {
            if occurrence.isCompleted {
                previousWasMiss = false
            } else {
                if previousWasMiss, occurrence.day >= earliest { return occurrence.day }
                previousWasMiss = true
            }
        }
        return nil
    }
}
