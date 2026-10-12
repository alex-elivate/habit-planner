import Foundation
import Testing
@testable import HabitKit

@Suite("Export")
struct HabitExportTests {
    let water = Habit(title: "Drink water", routine: .morning, order: 0, startedOn: referenceToday.advanced(by: -10))
    let meds = Habit(title: "Meds, \"evening\"", routine: .evening, order: 0, startedOn: referenceToday.advanced(by: -10))

    /// 08:15 UTC on `referenceToday`.
    var morning: Date { Date(timeIntervalSince1970: TimeInterval(referenceToday.ordinal) * 86_400 + 8.25 * 3_600) }

    func export(_ completions: [CompletionEvent]) -> HabitExport {
        HabitExport(exportedAt: morning, habits: [water, meds], completions: completions, lifecycle: [],
                    routineRuns: [], plannedHabits: [], unreadableRecords: [])
    }

    @Test("Every record comes back the same from the JSON")
    func roundTrip() throws {
        let done = CompletionEvent(habitID: water.id, dayKey: referenceToday, occurredAt: morning, timeZoneIdentifier: "UTC")
        let plan = PlannedHabit(routine: .morning, title: "Stretch", recordedAt: morning)
        let original = HabitExport(exportedAt: morning, habits: [water], completions: [done], lifecycle: [],
                                   routineRuns: [], plannedHabits: [plan],
                                   unreadableRecords: ["a record"])
        let decoded = try HabitExport.decode(try original.json())
        #expect(decoded.format == HabitExport.currentFormat)
        #expect(decoded.exportedAt == morning)
        #expect(decoded.habits == [water])
        #expect(decoded.completions.map(\.id) == [done.id])
        #expect(decoded.completions.first?.occurredAt == morning)
        #expect(decoded.plannedHabits == [plan])
        #expect(decoded.unreadableRecords == ["a record"])
    }

    @Test("The same data makes the same file, whatever order the store read it in")
    func stableOrder() throws {
        let a = CompletionEvent(habitID: water.id, dayKey: referenceToday, occurredAt: morning, timeZoneIdentifier: "UTC")
        let b = CompletionEvent(habitID: water.id, dayKey: referenceToday.advanced(by: -1), occurredAt: morning, timeZoneIdentifier: "UTC")
        #expect(try export([a, b]).json() == export([b, a]).json())
    }

    @Test("The spreadsheet has a row per marked day, a taken-back day reads Not done, and odd titles stay in one cell")
    func csv() {
        let done = CompletionEvent(habitID: meds.id, dayKey: referenceToday, source: .automatic,
                                   occurredAt: morning, timeZoneIdentifier: "UTC")
        let undone = CompletionEvent(habitID: water.id, dayKey: referenceToday.advanced(by: -1), status: .retracted,
                                     occurredAt: morning, timeZoneIdentifier: "UTC")
        let lines = export([done, undone]).completionsCSV().components(separatedBy: "\r\n")
        #expect(lines == [
            "Date,Routine,Habit,Result,Recorded by,Done at,Time zone",
            "2026-09-20,Morning,Drink water,Not done,You,,UTC",
            "2026-09-21,Evening,\"Meds, \"\"evening\"\"\",Done,Health,08:15,UTC",
            "",
        ])
    }

    @Test("A title a spreadsheet would run as a formula is shown as text")
    func formulaTitles() {
        #expect(HabitExport.csvField("=SUM(A1)") == "'=SUM(A1)")
        #expect(HabitExport.csvField("-5 pushups, slow") == "\"'-5 pushups, slow\"")
        #expect(HabitExport.csvField("Walk") == "Walk")
    }

    @Test("Done at is the time where it was done")
    func localTime() {
        #expect(HabitExport.localTime(morning, in: "America/Phoenix") == "01:15")
        #expect(HabitExport.localTime(morning, in: "UTC") == "08:15")
    }
}
