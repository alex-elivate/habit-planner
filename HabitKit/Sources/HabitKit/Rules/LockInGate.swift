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
        /// Sessions done among the ones the rate is judged on: all of them until there are
        /// `requiredOccurrences`, then the latest that many.
        public let completedOccurrences: Int
        public let rate: Double?
        public let requiredRate: Double
        public let recentDoubleMiss: DayKey?
        public let decision: Decision

        public var isLockedIn: Bool { decision.isOpen }

        /// How far along the repetition requirement is, 0 through 1.
        ///
        /// Counts time, not completions, so every habit that joined on the same day shows the
        /// same value. For showing how close a habit is to bedding in, use `bedInProgress`.
        public var repetitionProgress: Double {
            guard requiredOccurrences > 0 else { return 1 }
            return min(1, Double(elapsedOccurrences) / Double(requiredOccurrences))
        }

        /// Sessions that must be done out of `requiredOccurrences` to meet `requiredRate`.
        public var requiredCompletions: Int {
            Int((requiredRate * Double(requiredOccurrences)).rounded(.up))
        }

        /// How far the habit is towards bedding in, 0 through 1: sessions done against the
        /// number needed. Unlike `repetitionProgress`, a habit done every day moves ahead of
        /// one done twice. Full is necessary but not sufficient, since a recent double miss
        /// still holds the gate.
        public var bedInProgress: Double {
            guard requiredCompletions > 0 else { return 1 }
            return min(1, Double(completedOccurrences) / Double(requiredCompletions))
        }

        /// Sessions missed among the ones the rate is judged on.
        public var missedOccurrences: Int {
            min(elapsedOccurrences, requiredOccurrences) - completedOccurrences
        }

        /// Whether the habit can still bed in by its `requiredOccurrences`th session. Once more
        /// sessions are missed than the rate allows, it needs longer, as later sessions push
        /// the early misses out of the window.
        public var canBedInOnTime: Bool {
            missedOccurrences <= requiredOccurrences - requiredCompletions
        }
    }

    /// Judges a single habit.
    public static func assess(_ history: HabitHistory) -> Assessment {
        assess(history.habit.id, occurrences: history.settledOccurrences, today: history.today)
    }

    /// Whether `history` needs help to bed in: waiting alone will not get it there.
    ///
    /// Either it has missed more than 28 sessions allow, or two misses in a row will still be
    /// holding it when it reaches its 28th session. A double miss early on is not enough by
    /// itself, since it stops counting after `doubleMissWindowDays` and a daily habit takes
    /// 28 days to reach 28 sessions. Projected on the habit's schedule from today, ignoring
    /// any pause to come.
    public static func isBehind(_ history: HabitHistory) -> Bool {
        let assessment = assess(history)
        guard !assessment.isLockedIn else { return false }
        if !assessment.canBedInOnTime { return true }
        guard let secondMiss = assessment.recentDoubleMiss else { return false }
        let clears = secondMiss.advanced(by: doubleMissWindowDays + 1)
        let needed = assessment.requiredOccurrences - assessment.elapsedOccurrences
        // Past 28 sessions with enough done, a pair holding the gate clears by waiting.
        guard needed > 0 else { return false }
        // The day of the 28th session: today counts, since it is not settled yet.
        var day = history.today
        var found = 0
        for _ in 0..<(needed * 7 + 7) {
            if history.habit.isScheduled(on: day) {
                found += 1
                if found == needed { break }
            }
            day = day.advanced(by: 1)
        }
        // The gate judges the 28th session the day after it, once it has settled.
        return day.advanced(by: 1) < clears
    }

    /// Judges a habit on `occurrences` alone, as if `today` were the day after the last.
    private static func assess(_ habitID: UUID, occurrences: [ScheduledOccurrence], today: DayKey) -> Assessment {
        let window = occurrences.suffix(requiredOccurrences)
        let completed = window.count(where: \.isCompleted)
        let rate: Double? = window.isEmpty ? nil : Double(completed) / Double(window.count)

        let doubleMiss = latestDoubleMiss(
            in: occurrences,
            secondMissOnOrAfter: today.advanced(by: -doubleMissWindowDays)
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
            habitID: habitID,
            elapsedOccurrences: occurrences.count,
            requiredOccurrences: requiredOccurrences,
            completedOccurrences: completed,
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
    ///
    /// Judged on its record from before it was archived, not on today's, so its place is
    /// settled at the restore and a rough week later cannot send it to the back of the queue.
    public static func gateJoinDay(_ history: HabitHistory) -> DayKey {
        let joined = history.lifecycle.joinedRoutine(asOf: history.today)
        guard joined != history.habit.startedOn, hadBeddedInBeforeLeaving(history) else { return joined }
        return history.habit.startedOn
    }

    /// Whether `history` had bedded in when it was last archived. For a habit never archived,
    /// whether it has bedded in now.
    public static func hadBeddedInBeforeLeaving(_ history: HabitHistory) -> Bool {
        let today = history.today
        guard let left = history.lifecycle.transitions.last(where: { $0.state == .archived && $0.day <= today })?.day
        else { return assess(history).isLockedIn }
        let before = history.settledOccurrences.filter { $0.day < left }
        return assess(history.habit.id, occurrences: before, today: left).isLockedIn
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
        return canAddHabit(to: habit.habit.routine, histories: others).isOpen || hadBeddedInBeforeLeaving(habit)
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
    /// The latest miss that follows another miss, on or after `earliest`.
    ///
    /// The latest rather than the first, because it is the one that counts longest. Found in
    /// review: with pairs ten days apart, reporting the first said the gate would clear days
    /// before it did.
    private static func latestDoubleMiss(
        in occurrences: [ScheduledOccurrence],
        secondMissOnOrAfter earliest: DayKey
    ) -> DayKey? {
        var previousWasMiss = false
        var latest: DayKey?
        for occurrence in occurrences {
            if occurrence.isCompleted {
                previousWasMiss = false
            } else {
                if previousWasMiss, occurrence.day >= earliest { latest = occurrence.day }
                previousWasMiss = true
            }
        }
        return latest
    }
}
