import Foundation
import HabitKit
import Testing
@testable import HabitStore

@Suite("Mapping")
struct MappingTests {

    // MARK: Round trips

    @Test("A habit survives the round trip unchanged")
    func habitRoundTrips() throws {
        let habit = sampleHabit(schedule: .daysOfWeek([.monday, .wednesday, .friday]), source: .automatic)
        #expect(try StoredHabit(habit).toDomain() == habit)
    }

    @Test("A daily habit with every optional empty survives the round trip")
    func minimalHabitRoundTrips() throws {
        let habit = Habit(title: "", routine: .evening, order: 0, startedOn: referenceToday)
        #expect(try StoredHabit(habit).toDomain() == habit)
    }

    @Test("Every weekday combination survives the round trip", arguments: 1...127)
    func everyScheduleMaskRoundTrips(mask: Int) throws {
        let days = StoredSchedule.days(from: mask)
        let habit = sampleHabit(schedule: .daysOfWeek(days))
        let restored = try StoredHabit(habit).toDomain()
        #expect(restored.schedule == .daysOfWeek(days))
        #expect(days.count == mask.nonzeroBitCount)
    }

    @Test("A completion survives the round trip, including both clocks")
    func completionRoundTrips() throws {
        let event = completion(
            UUID(), referenceToday.advanced(by: -3),
            occurredAt: Date(timeIntervalSince1970: 1_000),
            recordedAt: Date(timeIntervalSince1970: 90_000)
        )
        let restored = try StoredCompletionEvent(event).toDomain()
        #expect(restored.id == event.id)
        #expect(restored.occurredAt == event.occurredAt)
        #expect(restored.recordedAt == event.recordedAt)
        #expect(restored.status == event.status)
        #expect(restored.timeZoneIdentifier == event.timeZoneIdentifier)
    }

    @Test("A retraction survives the round trip and keeps its sibling's identifier")
    func retractionRoundTrips() throws {
        let done = completion(UUID(), referenceToday.advanced(by: -1))
        let undone = done.retracted(at: Date(timeIntervalSince1970: 50_000))
        let restored = try StoredCompletionEvent(undone).toDomain()
        #expect(restored.status == .retracted)
        #expect(restored.id == done.id)
    }

    @Test("A lifecycle event survives the round trip", arguments: LifecycleEvent.State.allCases)
    func lifecycleRoundTrips(state: LifecycleEvent.State) throws {
        let event = LifecycleEvent(habitID: UUID(), dayKey: referenceToday, state: state,
                                   occurredAt: Date(timeIntervalSince1970: 7), timeZoneIdentifier: "UTC")
        let restored = try StoredLifecycleEvent(event).toDomain()
        #expect(restored.state == state)
        #expect(restored.id == event.id)
    }

    @Test("A routine run survives the round trip with its steps in order")
    func routineRunRoundTrips() throws {
        let first = UUID(), second = UUID(), third = UUID()
        let run = RoutineRun(
            routine: .evening,
            dayKey: referenceToday,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_600),
            timeZoneIdentifier: "Europe/London",
            steps: [
                RoutineStep(habitID: third, position: 2, startedAt: Date(timeIntervalSince1970: 1_400)),
                RoutineStep(habitID: first, position: 0,
                            startedAt: Date(timeIntervalSince1970: 1_000),
                            endedAt: Date(timeIntervalSince1970: 1_120)),
                RoutineStep(habitID: second, position: 1, startedAt: Date(timeIntervalSince1970: 1_120))
            ]
        )

        let restored = try StoredRoutineRun(run).toDomain()
        #expect(restored.id == run.id)
        #expect(restored.steps.map(\.habitID) == [first, second, third])
        #expect(restored.duration == 600)
        #expect(restored.steps[0].duration == 120)
        // A step that was reached but never finished has no duration, and that is not an error.
        #expect(restored.steps[2].duration == nil)
    }

    // MARK: The stored spelling is pinned to the domain's own

    @Test("Stored schedule kinds match what the domain encodes")
    func scheduleKindsMatchDomainEncoding() throws {
        // The store flattens `Schedule` by hand into two columns that freeze with the CloudKit
        // schema. This pins those spellings to the domain's hand-written Codable, so the two
        // cannot drift apart once nobody is reading both files at once.
        func encoded(_ schedule: Schedule) throws -> [String: Any] {
            let data = try JSONEncoder().encode(schedule)
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }

        let daily = try encoded(.daily)
        #expect(daily["kind"] as? String == StoredSchedule.Kind.daily.rawValue)

        let days: Set<Weekday> = [.tuesday, .thursday]
        let weekly = try encoded(.daysOfWeek(days))
        #expect(weekly["kind"] as? String == StoredSchedule.Kind.daysOfWeek.rawValue)
        #expect(weekly["days"] as? Int == StoredSchedule.mask(for: days))
    }

    // MARK: Rejections

    @Test("A zeroed day is rejected rather than folded")
    func zeroedDayIsRejected() throws {
        // `0` is what a missing or zeroed CloudKit Int64 reads as, and its ordinal is
        // -719560. Accepting it means folding a 740,000 element array inside a widget.
        let row = StoredHabit(habitID: UUID(), title: "x", startedOnRaw: 0)
        #expect(throws: StoreMappingError.self) { try row.toDomain() }

        let event = StoredCompletionEvent(eventID: "x", dayKeyRaw: 0)
        #expect(throws: StoreMappingError.self) { try event.toDomain() }
    }

    @Test("A day that does not exist on the calendar is rejected")
    func impossibleDayIsRejected() throws {
        // 30 February 2026.
        let row = StoredHabit(habitID: UUID(), title: "x", startedOnRaw: 20_260_230)
        #expect(throws: StoreMappingError.self) { try row.toDomain() }
    }

    @Test("A weekly habit due on no day at all is rejected")
    func emptyWeekdayMaskIsRejected() throws {
        // A habit due on no day accrues no scheduled occurrences, so the lock-in gate can
        // never see enough history and the routine stays shut permanently with nothing on
        // screen explaining why.
        let row = StoredHabit(
            habitID: UUID(), title: "x",
            scheduleKindRaw: StoredSchedule.Kind.daysOfWeek.rawValue,
            scheduleDayMask: 0,
            startedOnRaw: referenceToday.rawValue
        )
        #expect(throws: StoreMappingError.self) { try row.toDomain() }
    }

    @Test("A weekday mask with bits outside the week is rejected")
    func outOfRangeWeekdayMaskIsRejected() throws {
        let row = StoredHabit(
            habitID: UUID(), title: "x",
            scheduleKindRaw: StoredSchedule.Kind.daysOfWeek.rawValue,
            scheduleDayMask: 1 << 9,
            startedOnRaw: referenceToday.rawValue
        )
        #expect(throws: StoreMappingError.self) { try row.toDomain() }
    }

    @Test("A raw value from a newer version is rejected, not silently defaulted")
    func unknownRawValueIsRejected() throws {
        let row = StoredHabit(habitID: UUID(), title: "x", routineRaw: "afternoon",
                              startedOnRaw: referenceToday.rawValue)
        #expect(throws: StoreMappingError.self) { try row.toDomain() }

        let source = StoredHabit(habitID: UUID(), title: "x", completionSourceRaw: "telepathy",
                                 startedOnRaw: referenceToday.rawValue)
        #expect(throws: StoreMappingError.self) { try source.toDomain() }
    }

    @Test("An identifier that does not address its own content is rejected")
    func identifierMismatchIsRejected() throws {
        // Every dedup path in the app assumes the identifier is derivable from the record.
        // A row where it is not has already broken deduplication, so it is reported rather
        // than quietly repaired.
        let row = StoredCompletionEvent(
            eventID: "not-the-content-address",
            habitID: UUID(),
            dayKeyRaw: referenceToday.rawValue,
            slotIndex: 0
        )
        #expect(throws: StoreMappingError.self) { try row.toDomain() }
    }
}
