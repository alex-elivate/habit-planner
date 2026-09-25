import Foundation
import Testing
@testable import HabitKit

@Suite("Health backfill")
struct HealthBackfillTests {

    let utc = TimeZone(identifier: "UTC")!

    func binding(lastReconciled: DayKey) -> HealthBinding {
        HealthBinding(habitID: UUID(), signal: .workout, lastReconciledDay: lastReconciled)
    }

    /// Noon UTC on `day`.
    func noon(_ day: DayKey) -> Date {
        Date(timeIntervalSince1970: TimeInterval(day.ordinal) * 86_400 + 43_200)
    }

    // MARK: - Which days

    @Test("Covers the day after the last reconciliation through yesterday, never today")
    func range() {
        let range = HealthBackfill.daysToReconcile(binding(lastReconciled: referenceToday.advanced(by: -3)),
                                                   today: referenceToday)
        #expect(range == referenceToday.advanced(by: -2)...referenceToday.advanced(by: -1))
    }

    @Test("Nothing to do when already caught up, or when the binding was made today")
    func caughtUp() {
        #expect(HealthBackfill.daysToReconcile(binding(lastReconciled: referenceToday.advanced(by: -1)),
                                               today: referenceToday) == nil)
        #expect(HealthBackfill.daysToReconcile(binding(lastReconciled: referenceToday),
                                               today: referenceToday) == nil)
    }

    @Test("A long absence is capped, so a late grant cannot rewrite a quarter of history")
    func capped() throws {
        let range = try #require(HealthBackfill.daysToReconcile(
            binding(lastReconciled: referenceToday.advanced(by: -90)), today: referenceToday))
        #expect(range.lowerBound == referenceToday.advanced(by: -HealthBackfill.maximumDays))
        #expect(range.upperBound == referenceToday.advanced(by: -1))
    }

    // MARK: - Which proposals

    func history(schedule: Schedule = .daily, pausedFrom: DayKey? = nil) -> HabitHistory {
        let habit = Habit(title: "Walk", routine: .morning, order: 0, schedule: schedule,
                          completionSource: .automatic, startedOn: referenceToday.advanced(by: -30))
        let lifecycle = pausedFrom.map {
            [LifecycleEvent(habitID: habit.id, dayKey: $0, state: .paused,
                            occurredAt: .distantPast, timeZoneIdentifier: "UTC")]
        } ?? []
        return HabitHistory(habit: habit, events: [], lifecycle: lifecycle, today: referenceToday)
    }

    @Test("One proposal per day, at the earliest signal, marked as signal-asserted")
    func onePerDay() throws {
        let day = referenceToday.advanced(by: -2)
        let recordedAt = noon(referenceToday)
        let proposals = HealthBackfill.proposals(
            for: history(), in: day...day,
            signalInstants: [noon(day), noon(day).addingTimeInterval(-7_200), noon(day).addingTimeInterval(3_600)],
            recordedAt: recordedAt, timeZone: utc
        )
        let only = try #require(proposals.first)
        #expect(proposals.count == 1)
        #expect(only.dayKey == day)
        #expect(only.occurredAt == noon(day).addingTimeInterval(-7_200))
        #expect(only.recordedAt == recordedAt)
        #expect(only.source == .automatic)
        #expect(only.status == .completed)
    }

    @Test("Signals outside the range, on rest days, or while paused propose nothing")
    func filtered() {
        let range = referenceToday.advanced(by: -7)...referenceToday.advanced(by: -1)
        let outside = [noon(referenceToday.advanced(by: -8)), noon(referenceToday)]
        #expect(HealthBackfill.proposals(for: history(), in: range, signalInstants: outside,
                                         recordedAt: .now, timeZone: utc).isEmpty)

        // referenceToday is a Monday, so -1 is a Sunday.
        let sunday = [noon(referenceToday.advanced(by: -1))]
        #expect(HealthBackfill.proposals(for: history(schedule: .daysOfWeek([.monday])), in: range,
                                         signalInstants: sunday, recordedAt: .now, timeZone: utc).isEmpty)

        let whilePaused = [noon(referenceToday.advanced(by: -2))]
        #expect(HealthBackfill.proposals(for: history(pausedFrom: referenceToday.advanced(by: -3)), in: range,
                                         signalInstants: whilePaused, recordedAt: .now, timeZone: utc).isEmpty)
    }

    @Test("The day is resolved in the zone given, so a late-evening walk west of UTC stays on its day")
    func timeZone() throws {
        let newYork = TimeZone(identifier: "America/New_York")!
        let day = referenceToday.advanced(by: -2)
        // 02:00 UTC on the following day is 22:00 the previous evening in New York.
        let instant = noon(day.advanced(by: 1)).addingTimeInterval(-10 * 3_600)
        let proposal = try #require(HealthBackfill.proposals(
            for: history(), in: day...day.advanced(by: 1), signalInstants: [instant],
            recordedAt: .now, timeZone: newYork).first)
        #expect(proposal.dayKey == day)
        #expect(proposal.timeZoneIdentifier == "America/New_York")
    }
}
