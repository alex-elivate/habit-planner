import Foundation
import HabitKit

nonisolated extension LockInGate.Assessment {
    /// What stands between this habit and the next, in the terms the person can act on.
    var explanation: String {
        let sessions = "\(min(elapsedOccurrences, requiredOccurrences)) of \(requiredOccurrences) sessions"
        let rateText = rate.map { "\(Int(($0 * 100).rounded()))%" }
        let needed = "\(Int((requiredRate * 100).rounded()))%"
        switch decision {
        case .open:
            return "Bedded in."
        case .blocked(.notEnoughHistory):
            return rateText.map { "\(sessions), \($0) so far." } ?? "\(sessions)."
        case .blocked(.rateTooLow):
            return "\(sessions) done at \(rateText ?? "–"). Needs \(needed)."
        case .blocked(.recentDoubleMiss(let day)):
            // The pair counts while its second miss is within the window, so it drops out
            // the day after the window passes it.
            let missed = day.start(in: .current).formatted(.dateTime.month().day())
            let clears = day.advanced(by: LockInGate.doubleMissWindowDays + 1)
                .start(in: .current).formatted(.dateTime.month().day())
            return "Missed twice in a row on \(missed). That stops counting on \(clears)."
        }
    }
}
