import Foundation
import Testing
@testable import HabitKit

@Suite("Never miss twice")
struct StreakTests {

    struct Case: Sendable, CustomStringConvertible {
        let pattern: String
        let expected: StreakState
        let note: String
        var description: String { "\(pattern.isEmpty ? "(empty)" : pattern) — \(note)" }
    }

    @Test("Streak state follows the never-miss-twice rule", arguments: [
        Case(pattern: "", expected: .healthy(length: 0), note: "a brand new habit has nothing to break"),
        Case(pattern: "C", expected: .healthy(length: 1), note: "one day in"),
        Case(pattern: "CCCCC", expected: .healthy(length: 5), note: "an unbroken run"),
        Case(pattern: "CCCMC", expected: .healthy(length: 4), note: "a single miss costs the day, not the streak"),
        Case(pattern: "CCCCM", expected: .recovery(length: 4), note: "missed yesterday, one chance left"),
        Case(pattern: "M", expected: .recovery(length: 0), note: "missed the only day so far"),
        Case(pattern: "CCCMM", expected: .broken, note: "two in a row ends it"),
        Case(pattern: "CCMMC", expected: .healthy(length: 1), note: "an older double-miss caps the count"),
        Case(pattern: "CMCMCM", expected: .recovery(length: 3), note: "alternating never misses twice"),
        Case(pattern: "MMCCC", expected: .healthy(length: 3), note: "a rough start does not haunt a good run"),
        Case(pattern: "MM", expected: .broken, note: "two misses and nothing else")
    ])
    func streakState(testCase: Case) {
        #expect(makeHistory(testCase.pattern).streak == testCase.expected, "\(testCase)")
    }

    @Test("An unfinished today is not a miss")
    func todayIsNotAMiss() {
        // The morning routine is not yet done. Yesterday and before were perfect.
        let history = makeHistory("CCCCC", completedToday: false)
        #expect(history.streak == .healthy(length: 5))
        #expect(history.isDueToday)
        #expect(!history.isCompletedToday)
    }

    @Test("Recovery is flagged so the interface can say something")
    func recoveryIsVisible() {
        #expect(makeHistory("CCCCM").streak.isAtRisk)
        #expect(!makeHistory("CCCCC").streak.isAtRisk)
        #expect(!makeHistory("CCCMM").streak.isAtRisk)
    }
}
