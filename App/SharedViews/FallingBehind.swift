import HabitKit
import SwiftUI

/// Which part of a habit the editor opens on.
enum HabitEditorFocus: Hashable {
    case twoMinuteVersion
    case cue
    case schedule
}

/// A request to open the editor, on one field or none. Presented as a sheet item, so the
/// field travels with the request rather than in a second piece of state the sheet might read
/// before it is set.
struct HabitEditRequest: Identifiable {
    let id = UUID()
    var focus: HabitEditorFocus?
}

/// Ideas for a habit that will not bed in by waiting alone. See `LockInGate.isBehind`.
///
/// Changes to the habit itself, the ones the habit method suggests: make it easier to start,
/// tie it to something that already happens, or ask for it only on days that can be kept.
/// Each opens the editor on that field. A schedule change that would open the routine early
/// is still refused there.
struct FallingBehind {
    let history: HabitHistory
    let assessment: LockInGate.Assessment

    var title: String { "\(history.habit.title) is falling behind" }

    var reason: String {
        let advice = "A change that makes it easier to start helps more than waiting."
        if assessment.recentDoubleMiss != nil, assessment.canBedInOnTime {
            return "Missed twice in a row. \(advice)"
        }
        if assessment.elapsedOccurrences >= assessment.requiredOccurrences {
            return "Missed \(assessment.missedOccurrences) of the last \(assessment.requiredOccurrences) sessions. It beds in once \(assessment.requiredCompletions) of the latest \(assessment.requiredOccurrences) are done. \(advice)"
        }
        return "Missed \(assessment.missedOccurrences) of \(assessment.elapsedOccurrences) sessions. It now needs more than \(assessment.requiredOccurrences) sessions to bed in. \(advice)"
    }

    /// The three ideas as buttons, for a list section or a box.
    @ViewBuilder
    func ideas(edit: @escaping (HabitEditorFocus) -> Void) -> some View {
        idea("Make it smaller", systemImage: "arrow.down.right.and.arrow.up.left",
             detail: history.habit.twoMinuteVersion.map { "Now: \($0). Try something smaller still." }
                ?? "Set a version you can do in two minutes.",
             focus: .twoMinuteVersion, edit: edit)
        idea("Tie it to a cue", systemImage: "link",
             detail: history.habit.cue.map { "Now: \($0). Pick something you never skip." }
                ?? "Do it right after something you already do every \(history.habit.routine.title.lowercased()).",
             focus: .cue, edit: edit)
        idea("Change its days", systemImage: "calendar",
             detail: "Ask for it only on the days you can keep.",
             focus: .schedule, edit: edit)
    }

    private func idea(_ title: String, systemImage: String, detail: String,
                      focus: HabitEditorFocus, edit: @escaping (HabitEditorFocus) -> Void) -> some View {
        Button { edit(focus) } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: systemImage)
            }
        }
        .accessibilityIdentifier("behind.\(focus)")
    }
}

/// `FallingBehind` as a section of a list.
struct FallingBehindSection: View {
    let behind: FallingBehind
    let edit: (HabitEditorFocus) -> Void

    var body: some View {
        Section {
            behind.ideas(edit: edit)
        } header: {
            Text(behind.title)
        } footer: {
            Text(behind.reason)
        }
    }
}
