import Foundation
import HabitKit

nonisolated extension DayKey {
    /// The instant this civil day begins in `timeZone`.
    ///
    /// Only the app needs this. The domain never turns a day back into a `Date`, because a day
    /// is resolved once and stored. Querying Health and scheduling notifications are the two
    /// places that have to ask the question the other way round.
    func start(in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day)
        // A valid civil day always has a start, even on a daylight-saving transition, where
        // Foundation returns the first instant that exists.
        return calendar.date(from: components)!
    }

    /// The day as an interval in `timeZone`, from its start to the next day's start.
    func interval(in timeZone: TimeZone) -> DateInterval {
        DateInterval(start: start(in: timeZone), end: advanced(by: 1).start(in: timeZone))
    }
}
