import Foundation
import HabitKit

nonisolated extension LockInGate.Assessment {
    /// What stands between this habit and the next, in the terms the person can act on.
    ///
    /// Leads with what was done, since that is what differs between habits. The time a habit
    /// has had is the same for every habit that joined on one day, and showing it first read
    /// as two habits being level when one was far behind.
    var explanation: String {
        let done = "Done on \(completedOccurrences) of"
        switch decision {
        case .open:
            return "Bedded in."
        case .blocked(.notEnoughHistory) where elapsedOccurrences == 0:
            return "Starts today. Beds in at \(requiredCompletions) of \(requiredOccurrences) sessions."
        case .blocked(.notEnoughHistory):
            var text = "\(done) \(elapsedOccurrences) sessions so far. Beds in at \(requiredCompletions) of \(requiredOccurrences)."
            if !canBedInOnTime { text += " It now needs more than \(requiredOccurrences) sessions." }
            if let doubleMiss = doubleMissNote { text += " " + doubleMiss }
            return text
        case .blocked(.rateTooLow):
            return "\(done) the last \(requiredOccurrences) sessions. Needs \(requiredCompletions)."
        case .blocked(.recentDoubleMiss):
            return doubleMissNote ?? "Missed twice in a row."
        }
    }

    /// Two misses in a row hold the gate even once everything else is met, so they are shown
    /// from the start rather than only when they are the last thing in the way.
    private var doubleMissNote: String? {
        guard let day = recentDoubleMiss else { return nil }
        // The pair counts while its second miss is within the window, so it drops out the
        // day after the window passes it.
        let missed = day.start(in: .current).formatted(.dateTime.month().day())
        let clears = day.advanced(by: LockInGate.doubleMissWindowDays + 1)
            .start(in: .current).formatted(.dateTime.month().day())
        return "Missed twice in a row on \(missed). That stops counting on \(clears)."
    }

    /// Done against needed, for a short label beside "Done".
    var completionsLabel: String { "\(completedOccurrences) of \(requiredCompletions)" }
}
