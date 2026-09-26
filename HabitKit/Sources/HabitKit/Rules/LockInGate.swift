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
    /// Only the habits that joined the routine most recently are examined, the newest
    /// **cohort**. Older habits have already earned their place, and re-judging them would
    /// mean one rough week retroactively locking a routine the person built months ago.
    ///
    /// A cohort is normally one habit. The exception is the **starting set**: on a routine's
    /// first day any number of habits can join, so somebody who already has a routine can
    /// enter all of it, and every one of them is then judged together. Two devices adding a
    /// habit each on the same day, before either has seen the other's, also form a cohort,
    /// and both are judged rather than whichever sorts last.
    ///
    /// A **paused** habit is still examined. Pausing is not a way past the gate: if pausing
    /// the newest habit released it, the person could add another, resume the first, and have
    /// two habits bedding in at once. A paused habit that has not bedded in therefore holds
    /// the routine until it is resumed and beds in, or is archived.
    ///
    /// An **archived** habit is out of the routine and never examined. Restoring one is
    /// adding it back. See `gateJoinDay(_:)` for where it queues and `canRestore(_:histories:)`
    /// for when that is allowed.
    public static func canAddHabit(
        to routine: RoutineSlot,
        histories: some Sequence<HabitHistory>
    ) -> Decision {
        let all = Array(histories)
        // The first habit in an empty routine is never gated, and neither is the rest of the
        // starting set on the day it is entered.
        guard !isSettingUp(routine, histories: all),
              let waitingOn = judged(in: routine, histories: all) else { return .open }
        return assess(waitingOn).decision
    }

    /// Whether `routine` is still taking its starting set: it has never had a habit, or every
    /// habit it has ever had started today.
    ///
    /// Worked out from start days alone, so nothing records that setup happened, and the
    /// window closes at midnight on its own. Archived habits count, so archiving a whole
    /// routine does not reopen it. Nor does winding the clock back to the first day: anything
    /// recorded after "today" means today is not the day it claims to be.
    public static func isSettingUp(
        _ routine: RoutineSlot,
        histories: some Sequence<HabitHistory>
    ) -> Bool {
        let ever = histories.filter { $0.habit.routine == routine }
        guard let today = ever.first?.today else { return true }
        return ever.allSatisfy { $0.habit.startedOn == today && !$0.hasRecordsAfterToday }
    }

    /// The day `history` counts as having joined its routine, for the gate's ordering.
    ///
    /// Its lifecycle's join day: the start day, or the day of its latest restore. Except that
    /// a habit restored after it had bedded in takes its old place back. It earned that place
    /// before it left, and queueing it as the newest would let it stand in for a habit still
    /// bedding in and open the gate early.
    public static func gateJoinDay(_ history: HabitHistory) -> DayKey {
        let joined = history.lifecycle.joinedRoutine(asOf: history.today)
        guard joined != history.habit.startedOn, assess(history).isLockedIn else { return joined }
        return history.habit.startedOn
    }

    /// The habits the gate judges for `routine`: those sharing the latest `gateJoinDay`.
    public static func newestCohort(
        in routine: RoutineSlot,
        histories: some Sequence<HabitHistory>
    ) -> [HabitHistory] {
        let members = inRoutine(routine, histories).map { ($0, gateJoinDay($0)) }
        guard let latest = members.map(\.1).max() else { return [] }
        return members.filter { $0.1 == latest }.map(\.0)
    }

    /// The habits in the newest cohort that have not bedded in, furthest behind first. Empty
    /// while the routine is in setup, when nothing is being waited on.
    ///
    /// Furthest behind is the fewest sessions elapsed, then the lowest rate. Ties break on the
    /// identifier, never on `order`: display position is mutable, and dragging a row must not
    /// change which habit is judged.
    public static func waitingOn(
        in routine: RoutineSlot,
        histories: some Sequence<HabitHistory>
    ) -> [HabitHistory] {
        let all = Array(histories)
        guard !isSettingUp(routine, histories: all) else { return [] }
        return newestCohort(in: routine, histories: all)
            .map { ($0, assess($0)) }
            .filter { !$0.1.isLockedIn }
            .sorted { lhs, rhs in
                if lhs.1.elapsedOccurrences != rhs.1.elapsedOccurrences {
                    return lhs.1.elapsedOccurrences < rhs.1.elapsedOccurrences
                }
                if lhs.1.rate != rhs.1.rate { return (lhs.1.rate ?? 0) < (rhs.1.rate ?? 0) }
                return lhs.0.habit.id.uuidString < rhs.0.habit.id.uuidString
            }
            .map(\.0)
    }

    /// The one habit whose assessment decides `canAddHabit`, or `nil` if the routine is empty:
    /// the newest cohort's habit furthest behind, or any of them once all have bedded in.
    public static func judged(
        in routine: RoutineSlot,
        histories: some Sequence<HabitHistory>
    ) -> HabitHistory? {
        let all = Array(histories)
        let cohort = newestCohort(in: routine, histories: all)
        if let behind = waitingOn(in: routine, histories: all).first { return behind }
        return cohort.max { $0.habit.id.uuidString < $1.habit.id.uuidString }
    }

    /// The habits in `routine` the gate can examine: every one that is not archived.
    private static func inRoutine(_ routine: RoutineSlot, _ histories: some Sequence<HabitHistory>) -> [HabitHistory] {
        histories.filter { $0.habit.routine == routine && $0.currentState != .archived }
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
