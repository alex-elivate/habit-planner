import Foundation

/// What a widget or complication shows, folded from the same records the app folds.
///
/// Computed, never stored. The widget opens the shared store read only and builds one of these
/// for each timeline entry, so what it shows is always a fold of the logs rather than a summary
/// the app wrote earlier that could have gone stale. The app builds one too, only to tell
/// whether anything a widget shows has changed and a reload is worth spending.
public struct Glance: Hashable, Sendable {

    /// The day the fold was made for.
    public let day: DayKey

    /// Morning then evening.
    public let routines: [RoutineGlance]

    /// Before this hour the morning routine is featured, from it the evening one.
    ///
    /// A fixed hour rather than the reminder times, which are a per-device preference the
    /// widget extension cannot read, and a widget that featured a different routine from the
    /// app beside it would be confusing for no gain.
    public static let eveningBeginsAtHour = 12

    /// Folds everything a widget shows.
    ///
    /// - Parameters:
    ///   - histories: folded for the day `instant` falls on in `timeZone`.
    ///   - runs: that day's runs, so a routine started earlier resumes where it was left.
    ///   - planned: resolved plans. Cleared ones are ignored.
    ///   - gateHasUnreadableInput: whether a record the gate depends on could not be read. The
    ///     gate is then shown as unavailable, never as open, for the same reason the app
    ///     refuses to add a habit in that state.
    public init(
        histories: [HabitHistory],
        runs: [RoutineSlot: RoutineRun],
        planned: [RoutineSlot: PlannedHabit],
        gateHasUnreadableInput: Bool,
        at instant: Date,
        in timeZone: TimeZone
    ) {
        let day = DayKey(instant, in: timeZone)
        self.day = day
        let current = histories.filter { $0.today == day }
        self.routines = RoutineSlot.allCases.map { routine in
            RoutineGlance(
                routine: routine,
                histories: current,
                run: runs[routine].flatMap { $0.dayKey == day ? $0 : nil },
                planned: planned.active(for: routine)?.title,
                gateHasUnreadableInput: gateHasUnreadableInput,
                at: instant,
                in: timeZone
            )
        }
    }

    /// A glance stated outright, for a widget placeholder or a preview. Everything real is
    /// folded through the other initializer.
    public init(day: DayKey, routines: [RoutineGlance]) {
        precondition(routines.map(\.routine) == RoutineSlot.allCases, "One glance per routine, in order")
        self.day = day
        self.routines = routines
    }

    /// Morning before `eveningBeginsAtHour`, evening from it, with no handover of any kind.
    ///
    /// What an unqualified request to act means. Showing the evening once the morning is done
    /// is right for a widget, which only shows. Ticking an evening habit at 7:30 because
    /// somebody said "mark my habit done" is not, so acting intents use this instead.
    public static func routine(forTimeOf instant: Date, in timeZone: TimeZone) -> RoutineSlot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.component(.hour, from: instant) < eveningBeginsAtHour ? .morning : .evening
    }

    public func routine(_ slot: RoutineSlot) -> RoutineGlance {
        routines.first { $0.routine == slot }!
    }

    /// The routine to put first at `instant`.
    ///
    /// Morning until noon, evening from then on, with two exceptions that only ever move the
    /// widget towards something that can still be done:
    ///
    /// - A finished morning hands over to the evening straight away.
    /// - A routine with nothing due today gives way to one that has something due. Without this
    ///   an evening with no habits yet showed an empty card all evening while the morning, which
    ///   had work and a plan, stayed hidden. Found on the simulator, not by a test.
    ///
    /// An unfinished morning does not come back in the evening when the evening has work of its
    /// own. By then it has been missed, and featuring it would push the routine that can still
    /// be done out of view.
    public func featured(at instant: Date, in timeZone: TimeZone) -> RoutineSlot {
        let preferred = Self.routine(forTimeOf: instant, in: timeZone)
        let other: RoutineSlot = preferred == .morning ? .evening : .morning
        if !routine(preferred).hasWorkToday, routine(other).hasWorkToday { return other }
        if preferred == .morning, routine(.morning).remaining == 0, routine(.evening).remaining > 0 {
            return .evening
        }
        return preferred
    }
}

/// One routine as a widget shows it.
public struct RoutineGlance: Hashable, Sendable {

    /// How close the routine is to allowing another habit.
    public enum Unlock: Hashable, Sendable {
        /// A habit may be added now. Also the state of a routine with no habits yet, or one
        /// taking its starting set today.
        case open
        /// The newest habit is still bedding in.
        case beddingIn(habitTitle: String, assessment: LockInGate.Assessment)
        /// A record the gate reads could not be read, so no answer is trustworthy.
        case unavailable

        /// The gate's answer for `routine`, in the form both the app and the widgets show.
        ///
        /// The one place that decides it. The app refuses to add a habit exactly when this is
        /// not `.open`, so a widget can never call a routine unlocked while the app says no.
        public init(routine: RoutineSlot, histories: some Sequence<HabitHistory>, gateHasUnreadableInput: Bool) {
            // An unreadable newest habit drops out of the fold, and the gate would then judge
            // an older one that has already bedded in and open. Refusing is the safe direction.
            guard !gateHasUnreadableInput else {
                self = .unavailable
                return
            }
            // The gate's own selection, so the progress shown is the habit actually judged.
            // An empty routine, and one still taking its starting set, is never gated.
            let histories = Array(histories)
            guard !LockInGate.isSettingUp(routine, histories: histories),
                  let judged = LockInGate.judged(in: routine, histories: histories) else {
                self = .open
                return
            }
            let assessment = LockInGate.assess(judged)
            self = assessment.isLockedIn
                ? .open
                : .beddingIn(habitTitle: judged.habit.title, assessment: assessment)
        }

        public var isOpen: Bool { self == .open }
    }

    public let routine: RoutineSlot

    /// Done out of due today, among the routine's habits.
    public let progress: Progress

    /// The habit the runner would offer next, and how many it would offer in all.
    public let nextHabitTitle: String?
    public let remaining: Int

    public let unlock: Unlock

    /// The habit planned for when the routine unlocks.
    public let planned: String?

    /// A routine stated outright, for a placeholder or a preview.
    public init(
        routine: RoutineSlot,
        progress: Progress,
        nextHabitTitle: String?,
        remaining: Int,
        unlock: Unlock,
        planned: String?
    ) {
        self.routine = routine
        self.progress = progress
        self.nextHabitTitle = nextHabitTitle
        self.remaining = remaining
        self.unlock = unlock
        self.planned = planned
    }

    init(
        routine: RoutineSlot,
        histories: [HabitHistory],
        run: RoutineRun?,
        planned: String?,
        gateHasUnreadableInput: Bool,
        at instant: Date,
        in timeZone: TimeZone
    ) {
        self.routine = routine
        self.planned = planned

        let inRoutine = histories.filter { $0.habit.routine == routine }
        progress = ScoreEngine.todayProgress(for: inRoutine)

        // The runner's own plan, so the widget names the habit the runner would actually open
        // on, including after a run was left halfway.
        let runner = RoutineRunner(routine: routine, histories: inRoutine, resuming: run,
                                   at: instant, in: timeZone)
        remaining = runner.remaining.count
        nextHabitTitle = runner.currentHabitID.flatMap { id in
            inRoutine.first { $0.habit.id == id }?.habit.title
        }

        unlock = Unlock(routine: routine, histories: inRoutine, gateHasUnreadableInput: gateHasUnreadableInput)
    }

    /// Whether the routine has any habits due today at all.
    public var hasWorkToday: Bool { progress.total > 0 }
}
