import Foundation
import Testing
@testable import HabitKit

@Suite("Health matching")
struct HealthMatchingTests {
    let utc = TimeZone(identifier: "UTC")!
    /// Midnight UTC on `referenceToday`.
    var day: Date { Date(timeIntervalSince1970: TimeInterval(referenceToday.ordinal) * 86_400) }
    func at(_ hour: Double) -> Date { day.addingTimeInterval(hour * 3_600) }

    @Test("One dose linked in both routines counts in one of them, by the time it was taken")
    func splitAtNoon() {
        let doses = [at(8), at(21)]
        #expect(HealthMatching.instants(doses, for: .morning, signal: .medication, sharedAcrossRoutines: true, in: utc) == [at(8)])
        #expect(HealthMatching.instants(doses, for: .evening, signal: .medication, sharedAcrossRoutines: true, in: utc) == [at(21)])
        #expect(HealthMatching.instants([at(11.99)], for: .evening, signal: .medication, sharedAcrossRoutines: true, in: utc).isEmpty)
        #expect(HealthMatching.instants([at(12)], for: .evening, signal: .medication, sharedAcrossRoutines: true, in: utc) == [at(12)])
    }

    @Test("A reading linked in one routine counts at any time, except a morning dose for an evening habit")
    func notShared() {
        #expect(HealthMatching.instants([at(15)], for: .morning, signal: .medication, sharedAcrossRoutines: false, in: utc) == [at(15)])
        #expect(HealthMatching.instants([at(8)], for: .evening, signal: .workout, sharedAcrossRoutines: false, in: utc) == [at(8)])
        // A twice-daily drug linked only to the evening is not ticked by the morning dose.
        #expect(HealthMatching.instants([at(8), at(21)], for: .evening, signal: .medication, sharedAcrossRoutines: false, in: utc) == [at(21)])
    }

    @Test("The same drug in both routines is shared, different drugs are not")
    func sharing() {
        let morning = UUID(), evening = UUID(), other = UUID()
        let bindings = [
            HealthBinding(habitID: morning, signal: .medication, externalIdentifier: "codes:a", lastReconciledDay: referenceToday),
            HealthBinding(habitID: evening, signal: .medication, externalIdentifier: "codes:a", lastReconciledDay: referenceToday),
            HealthBinding(habitID: other, signal: .medication, externalIdentifier: "codes:b", lastReconciledDay: referenceToday),
        ]
        let routines = HealthMatching.routines(linking: bindings,
                                               habits: [morning: .morning, evening: .evening, other: .evening])
        #expect(routines["medication|codes:a"] == [.morning, .evening])
        #expect(routines["medication|codes:b"] == [.evening])
    }
}
