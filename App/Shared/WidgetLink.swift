import Foundation
import HabitKit

/// The URL a widget opens its app with, and the routine it asks to start.
///
/// A widget cannot run anything itself. It can only open the app, so the only thing a tap
/// carries is which routine to open the runner on. Anything else in the URL is ignored, and a
/// URL that names no routine opens the app on its first screen.
nonisolated enum WidgetLink {
    static let scheme = "habitplanner"

    static func url(for routine: RoutineSlot) -> URL {
        URL(string: "\(scheme)://run/\(routine.rawValue)")!
    }

    static func routine(from url: URL) -> RoutineSlot? {
        guard url.scheme == scheme, url.host() == "run" else { return nil }
        return RoutineSlot(rawValue: url.lastPathComponent)
    }

    /// The kind string every widget in the app is registered under.
    static let glanceKind = "org.trusler.habitplanner.glance"
}
