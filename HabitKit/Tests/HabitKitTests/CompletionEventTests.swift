import Foundation
import Testing
@testable import HabitKit

@Suite("CompletionEvent")
struct CompletionEventTests {

    @Test("The same completion recorded on two devices carries the same identifier")
    func deterministicIdentity() {
        let habitID = UUID()
        let day = DayKey(year: 2026, month: 9, day: 21)

        // Same logical completion, recorded seconds apart on watch and phone.
        let fromWatch = CompletionEvent(
            habitID: habitID, dayKey: day,
            occurredAt: Date(timeIntervalSince1970: 100), timeZoneIdentifier: "America/Phoenix"
        )
        let fromPhone = CompletionEvent(
            habitID: habitID, dayKey: day,
            occurredAt: Date(timeIntervalSince1970: 140), timeZoneIdentifier: "America/Phoenix"
        )

        #expect(fromWatch.id == fromPhone.id)
    }

    @Test("Different habits, days, or slots stay distinct")
    func distinctIdentity() {
        let habitID = UUID()
        let day = DayKey(year: 2026, month: 9, day: 21)
        let base = CompletionEvent(habitID: habitID, dayKey: day, occurredAt: .distantPast, timeZoneIdentifier: "UTC")

        let otherHabit = CompletionEvent(habitID: UUID(), dayKey: day, occurredAt: .distantPast, timeZoneIdentifier: "UTC")
        let otherDay = CompletionEvent(habitID: habitID, dayKey: day.advanced(by: 1), occurredAt: .distantPast, timeZoneIdentifier: "UTC")
        let otherSlot = CompletionEvent(habitID: habitID, dayKey: day, slotIndex: 1, occurredAt: .distantPast, timeZoneIdentifier: "UTC")

        #expect(base.id != otherHabit.id)
        #expect(base.id != otherDay.id)
        #expect(base.id != otherSlot.id)
    }

    @Test("Deduplication collapses sync duplicates and keeps the earliest instant")
    func deduplication() throws {
        let habitID = UUID()
        let day = DayKey(year: 2026, month: 9, day: 21)

        let events = [
            CompletionEvent(habitID: habitID, dayKey: day, occurredAt: Date(timeIntervalSince1970: 500), timeZoneIdentifier: "UTC"),
            CompletionEvent(habitID: habitID, dayKey: day, occurredAt: Date(timeIntervalSince1970: 100), timeZoneIdentifier: "UTC"),
            CompletionEvent(habitID: habitID, dayKey: day.advanced(by: 1), occurredAt: Date(timeIntervalSince1970: 900), timeZoneIdentifier: "UTC")
        ]

        let deduplicated = events.deduplicated()
        #expect(deduplicated.count == 2)

        let first = try #require(deduplicated.first)
        #expect(first.dayKey == day)
        #expect(first.occurredAt == Date(timeIntervalSince1970: 100))
    }

    @Test("Recording now resolves the day in the given zone")
    func resolvesDayOnRecord() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let phoenix = try #require(TimeZone(identifier: "America/Phoenix"))
        let instant = Date(timeIntervalSince1970: 1_789_972_200)  // 2026-09-21T06:30Z

        #expect(CompletionEvent(habitID: UUID(), at: instant, in: tokyo).dayKey == DayKey(year: 2026, month: 9, day: 21))
        #expect(CompletionEvent(habitID: UUID(), at: instant, in: phoenix).dayKey == DayKey(year: 2026, month: 9, day: 20))
    }
}
