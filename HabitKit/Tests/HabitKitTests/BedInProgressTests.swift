import Foundation
import Testing
@testable import HabitKit

/// Found on a device: a morning habit done five days of six and an evening habit done twice
/// showed the same bar, because the bar counted days.
@Suite("Bed-in progress")
struct BedInProgressTests {

    @Test("Two habits that joined on the same day show different progress when one is behind")
    func doneCountsNotDays() {
        let steady = LockInGate.assess(makeHistory("CCCMCC"))
        let behind = LockInGate.assess(makeHistory("CMMCMM"))
        #expect(steady.repetitionProgress == behind.repetitionProgress)

        #expect(steady.completedOccurrences == 5)
        #expect(behind.completedOccurrences == 2)
        #expect(steady.requiredCompletions == 24)
        #expect(abs(steady.bedInProgress - 5.0 / 24.0) < 0.0001)
        #expect(abs(behind.bedInProgress - 2.0 / 24.0) < 0.0001)
    }

    @Test("Four misses still leave room to bed in at 28 sessions, a fifth does not")
    func onTime() {
        #expect(LockInGate.assess(makeHistory("CMMCMM")).canBedInOnTime)
        #expect(!LockInGate.assess(makeHistory("CMMCMMM")).canBedInOnTime)
    }

    @Test("Past 28 sessions, only the latest 28 count")
    func window() {
        let history = makeHistory(pattern(length: 40, missesAt: Set(0..<12)))
        let assessment = LockInGate.assess(history)
        #expect(assessment.completedOccurrences == 28)
        #expect(assessment.bedInProgress == 1)
        #expect(assessment.isLockedIn)
    }

    @Test("A habit that has bedded in fills the bar")
    func full() {
        let assessment = LockInGate.assess(makeHistory(pattern(missesAt: [3, 9, 15, 21])))
        #expect(assessment.completedOccurrences == 24)
        #expect(assessment.bedInProgress == 1)
    }

    @Test("Behind: too many misses to bed in on time")
    func behindOnMisses() {
        #expect(!LockInGate.isBehind(makeHistory("CCMCCC")))
        let scattered = makeHistory("MCMCMCMCMC")
        #expect(LockInGate.assess(scattered).missedOccurrences == 5)
        #expect(LockInGate.isBehind(scattered))
        // Bedded in is never behind.
        #expect(!LockInGate.isBehind(makeHistory(pattern(missesAt: [3, 9, 15, 21]))))
    }

    @Test("An early double miss clears before session 28, a late one does not")
    func behindOnDoubleMiss() {
        // Second miss three days ago, 22 daily sessions still to go: it clears first.
        #expect(!LockInGate.isBehind(makeHistory("CCMMCC")))
        // Second miss yesterday, two sessions to go: it will still hold the gate.
        #expect(LockInGate.isBehind(makeHistory(String(repeating: "C", count: 24) + "MM")))
    }

    @Test("A pair that clears the day the 28th session is judged does not count")
    func behindBoundary() {
        // 26 sessions with the pair 14 and 13 days ago: it clears on day +2. Two daily
        // sessions to go, today and tomorrow, judged the day after: day +2. Not behind.
        let clearsInTime = pattern(length: 26, missesAt: [12, 13])
        #expect(!LockInGate.isBehind(makeHistory(clearsInTime)))
        // One day later and it still counts when judged.
        let stillCounts = pattern(length: 26, missesAt: [13, 14])
        #expect(LockInGate.isBehind(makeHistory(stillCounts)))
    }

    @Test("The latest of two pairs is the one that counts")
    func latestPair() {
        // Pairs ending 11 and 3 days ago: the second still counts at session 28.
        let history = makeHistory(pattern(length: 26, missesAt: [14, 15, 22, 23]))
        #expect(LockInGate.assess(history).recentDoubleMiss == referenceToday.advanced(by: -3))
        #expect(LockInGate.isBehind(history))
    }
}
