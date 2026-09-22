import Foundation
import HabitKit

// MARK: - Habit

extension StoredHabit {

    public convenience init(_ habit: Habit) {
        let schedule = StoredSchedule.flatten(habit.schedule)
        self.init(
            habitID: habit.id,
            title: habit.title,
            cue: habit.cue,
            twoMinuteVersion: habit.twoMinuteVersion,
            identityStatement: habit.identityStatement,
            routineRaw: habit.routine.rawValue,
            order: habit.order,
            scheduleKindRaw: schedule.kind.rawValue,
            scheduleDayMask: schedule.mask,
            completionSourceRaw: habit.completionSource.rawValue,
            startedOnRaw: habit.startedOn.rawValue
        )
    }

    /// Overwrites this record in place from `habit`.
    ///
    /// `habitID` and `startedOn` are deliberately not touched. Identity cannot change, and a
    /// habit's start day is the origin its whole history is counted from, so moving it would
    /// silently rewrite every score and gate assessment already made about it.
    public func update(from habit: Habit) {
        let schedule = StoredSchedule.flatten(habit.schedule)
        title = habit.title
        cue = habit.cue
        twoMinuteVersion = habit.twoMinuteVersion
        identityStatement = habit.identityStatement
        routineRaw = habit.routine.rawValue
        order = habit.order
        scheduleKindRaw = schedule.kind.rawValue
        scheduleDayMask = schedule.mask
        completionSourceRaw = habit.completionSource.rawValue
    }

    public func toDomain() throws -> Habit {
        let record = "StoredHabit(\(habitID))"

        guard let startedOn = DayKey(validating: startedOnRaw) else {
            throw StoreMappingError.invalidDayKey(record: record, field: "startedOnRaw", raw: startedOnRaw)
        }
        guard let routine = RoutineSlot(rawValue: routineRaw) else {
            throw StoreMappingError.unknownRawValue(record: record, field: "routineRaw", raw: routineRaw)
        }
        guard let source = CompletionSource(rawValue: completionSourceRaw) else {
            throw StoreMappingError.unknownRawValue(record: record, field: "completionSourceRaw", raw: completionSourceRaw)
        }
        guard let kind = StoredSchedule.Kind(rawValue: scheduleKindRaw) else {
            throw StoreMappingError.unknownRawValue(record: record, field: "scheduleKindRaw", raw: scheduleKindRaw)
        }

        let schedule: Schedule
        switch kind {
        case .daily:
            schedule = .daily
        case .daysOfWeek:
            // Empty is rejected as hard as out-of-range. A habit due on no day never accrues
            // an occurrence, so its routine's gate can never open again.
            guard scheduleDayMask != 0, scheduleDayMask & ~StoredSchedule.validMask == 0 else {
                throw StoreMappingError.malformedScheduleMask(record: record, raw: scheduleDayMask)
            }
            schedule = .daysOfWeek(StoredSchedule.days(from: scheduleDayMask))
        }

        return Habit(
            id: habitID,
            title: title,
            cue: cue,
            twoMinuteVersion: twoMinuteVersion,
            identityStatement: identityStatement,
            routine: routine,
            order: order,
            schedule: schedule,
            completionSource: source,
            startedOn: startedOn
        )
    }
}

// MARK: - Completion

extension StoredCompletionEvent {

    public convenience init(_ event: CompletionEvent) {
        self.init(
            eventID: event.id,
            habitID: event.habitID,
            dayKeyRaw: event.dayKey.rawValue,
            slotIndex: event.slotIndex,
            statusRaw: event.status.rawValue,
            occurredAt: event.occurredAt,
            recordedAt: event.recordedAt,
            timeZoneIdentifier: event.timeZoneIdentifier
        )
    }

    /// Overwrites this row with a resolved assertion about the same day.
    ///
    /// Identity fields are untouched, because a resolved assertion addresses the same
    /// `(habitID, dayKey, slotIndex)` by construction. What changes is which assertion won.
    public func update(from event: CompletionEvent) {
        statusRaw = event.status.rawValue
        occurredAt = event.occurredAt
        recordedAt = event.recordedAt
        timeZoneIdentifier = event.timeZoneIdentifier
    }

    public func toDomain() throws -> CompletionEvent {
        let record = "StoredCompletionEvent(\(eventID))"

        guard let dayKey = DayKey(validating: dayKeyRaw) else {
            throw StoreMappingError.invalidDayKey(record: record, field: "dayKeyRaw", raw: dayKeyRaw)
        }
        guard let status = CompletionEvent.Status(rawValue: statusRaw) else {
            throw StoreMappingError.unknownRawValue(record: record, field: "statusRaw", raw: statusRaw)
        }

        let event = CompletionEvent(
            habitID: habitID,
            dayKey: dayKey,
            slotIndex: slotIndex,
            status: status,
            occurredAt: occurredAt,
            recordedAt: recordedAt,
            timeZoneIdentifier: timeZoneIdentifier
        )

        // The content has to address the stored identifier, because every dedup path in the
        // app assumes it does.
        guard event.id == eventID else {
            throw StoreMappingError.identifierMismatch(record: record, stored: eventID, derived: event.id)
        }
        return event
    }
}

// MARK: - Lifecycle

extension StoredLifecycleEvent {

    public convenience init(_ event: LifecycleEvent) {
        self.init(
            eventID: event.id,
            habitID: event.habitID,
            dayKeyRaw: event.dayKey.rawValue,
            stateRaw: event.state.rawValue,
            occurredAt: event.occurredAt,
            timeZoneIdentifier: event.timeZoneIdentifier
        )
    }

    /// Overwrites this row with the decision that won for the same day.
    public func update(from event: LifecycleEvent) {
        stateRaw = event.state.rawValue
        occurredAt = event.occurredAt
        timeZoneIdentifier = event.timeZoneIdentifier
    }

    public func toDomain() throws -> LifecycleEvent {
        let record = "StoredLifecycleEvent(\(eventID))"

        guard let dayKey = DayKey(validating: dayKeyRaw) else {
            throw StoreMappingError.invalidDayKey(record: record, field: "dayKeyRaw", raw: dayKeyRaw)
        }
        guard let state = LifecycleEvent.State(rawValue: stateRaw) else {
            throw StoreMappingError.unknownRawValue(record: record, field: "stateRaw", raw: stateRaw)
        }

        let event = LifecycleEvent(
            habitID: habitID,
            dayKey: dayKey,
            state: state,
            occurredAt: occurredAt,
            timeZoneIdentifier: timeZoneIdentifier
        )
        guard event.id == eventID else {
            throw StoreMappingError.identifierMismatch(record: record, stored: eventID, derived: event.id)
        }
        return event
    }
}
