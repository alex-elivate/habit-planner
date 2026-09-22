import Foundation
import Testing
@testable import HabitKit

@Suite("Scoring")
struct ScoreEngineTests {

    @Test("Today's progress counts only what is due today")
    func todayProgress() {
        let histories = [
            makeHistory("CCC", completedToday: true),
            makeHistory("CCC", completedToday: true),
            makeHistory("CCC", completedToday: false),
            makeHistory("CCC", completedToday: false, state: .archived)
        ]

        let progress = ScoreEngine.todayProgress(for: histories)
        #expect(progress.completed == 2)
        #expect(progress.total == 3)  // the archived habit is not on the hook
        #expect(!progress.isComplete)
    }

    @Test("A rest day reads as an empty ring, not a full one")
    func restDay() {
        let progress = Progress(completed: 0, total: 0)
        #expect(progress.fraction == 0)
        #expect(!progress.isComplete)
    }

    @Test("The trailing rate ignores today, whether or not it is done")
    func trailingRateExcludesToday() {
        let perfectWeek = makeHistory(String(repeating: "C", count: 7), completedToday: false)
        #expect(ScoreEngine.trailingRate(for: [perfectWeek], days: 7) == 1.0)

        let perfectWeekDoneToday = makeHistory(String(repeating: "C", count: 7), completedToday: true)
        #expect(ScoreEngine.trailingRate(for: [perfectWeekDoneToday], days: 7) == 1.0)
    }

    @Test("The window only reaches back the days asked for")
    func windowIsBounded() {
        // Fourteen days of history, the older seven missed, the recent seven completed.
        let history = makeHistory(String(repeating: "M", count: 7) + String(repeating: "C", count: 7))
        #expect(ScoreEngine.trailingRate(for: [history], days: 7) == 1.0)
        #expect(ScoreEngine.trailingRate(for: [history], days: 14) == 0.5)
    }

    @Test("With no settled history there is no score to show")
    func noHistory() {
        let brandNew = makeHistory("")
        #expect(ScoreEngine.trailingRate(for: [brandNew]) == nil)
        #expect(ScoreEngine.score(for: [brandNew]) == nil)
        #expect(ScoreEngine.score(for: [HabitHistory]()) == nil)
    }

    @Test("The score rounds to a whole number out of a hundred")
    func scoreRounding() {
        // Five of seven days, twice, is 10 of 14 — 71.43%.
        let histories = [
            makeHistory("CCCCCMM"),
            makeHistory("CCCCCMM")
        ]
        #expect(ScoreEngine.score(for: histories, days: 7) == 71)
    }

    @Test("Habits are scored together, weighted by how often each was due")
    func weightedAcrossHabits() {
        let daily = makeHistory(String(repeating: "C", count: 7))
        let missedAll = makeHistory(String(repeating: "M", count: 7))
        #expect(ScoreEngine.score(for: [daily, missedAll], days: 7) == 50)
    }
}
