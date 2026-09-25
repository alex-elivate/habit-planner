import AppIntents
import HabitKit

/// A routine, as Siri and Shortcuts name it.
///
/// Its own type rather than `RoutineSlot` made to conform, because the App Intents metadata
/// processor reads an enum's cases from the source it is compiling and cannot see into
/// HabitKit. It rejects an imported enum at build time ("enums implemented in an imported
/// framework or library are not supported"). The mapping is one to one, and the test of that
/// is that `init(_:)` and `slot` are both exhaustive switches.
nonisolated enum RoutineChoice: String, AppEnum {
    case morning
    case evening

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Routine"

    static let caseDisplayRepresentations: [RoutineChoice: DisplayRepresentation] = [
        .morning: DisplayRepresentation(title: "Morning", image: .init(systemName: "sunrise")),
        .evening: DisplayRepresentation(title: "Evening", image: .init(systemName: "moon.stars")),
    ]

    init(_ slot: RoutineSlot) {
        switch slot {
        case .morning: self = .morning
        case .evening: self = .evening
        }
    }

    var slot: RoutineSlot {
        switch self {
        case .morning: .morning
        case .evening: .evening
        }
    }
}
