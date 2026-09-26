import AppIntents
import Foundation
import HabitKit
import HabitStore

// Every intent acts on the habit next in sequence and nothing else. There is no intent that
// ticks a habit by name: the order is the product, in the runner, in the widget and here.
// A routine left out means the one for the time of day when acting, and the one the widgets
// feature when only answering.

/// Opens the runner on a routine.
struct StartRoutineIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Routine"
    static let description = IntentDescription("Opens Habit Planner on a routine's next habit.")

    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Routine")
    var routine: RoutineChoice

    @Dependency private var actions: RoutineActions

    init() {}
    init(routine: RoutineSlot) { self.routine = RoutineChoice(routine) }

    static var parameterSummary: some ParameterSummary {
        Summary("Start the \(\.$routine) routine")
    }

    /// Hands the routine to the app's router, the path a tapped reminder takes.
    ///
    /// Not an `OpenURLIntent` on the widget's link: only the iPhone app registers that
    /// scheme, and a watch app has no URL types at all, so on the wrist it would open nothing.
    func perform() async throws -> some IntentResult {
        await actions.start(routine.slot)
        return .result()
    }
}

/// Marks the current habit done without opening anything, and says what comes next.
///
/// For Siri and Shortcuts. The widget's Done buttons use `CompleteMorningStepIntent` and
/// `CompleteEveningStepIntent`, below.
struct CompleteCurrentHabitIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Current Habit Done"
    static let description = IntentDescription(
        "Marks done the habit next in a routine, in the order the routine runs.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Routine")
    var routine: RoutineChoice?

    @Dependency private var actions: RoutineActions

    init() {}
    init(routine: RoutineSlot) { self.routine = RoutineChoice(routine) }

    static var parameterSummary: some ParameterSummary {
        Summary("Mark the current \(\.$routine) habit done")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Left out, it means the routine for the time of day, never the widget's handover. With
        // the morning finished at 7:30, "mark my habit done" must not tick tonight's habit.
        let slot = routine?.slot ?? Glance.routine(forTimeOf: .now, in: .current)
        let outcome = try await actions.completeCurrent(slot)
        return .result(dialog: IntentDialog(stringLiteral: outcome.spoken(for: slot)))
    }
}

// MARK: - The widget's Done buttons

// One intent per routine, each with no parameters, rather than `CompleteCurrentHabitIntent`
// with its routine filled in. The widget extension cannot read its own App Intents metadata
// ("Failed to fetch metadata"), so a parameter set there arrives in the app as nil. Nil means
// the routine for the time of day, so in the evening the morning button ticked nothing, and
// in the large widget the evening button ticked a morning habit. With nothing to pass, there
// is nothing to lose.

/// The Done button on the morning routine's widget.
struct CompleteMorningStepIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Current Morning Habit Done"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background

    @Dependency private var actions: RoutineActions

    func perform() async throws -> some IntentResult {
        _ = try await actions.completeCurrent(.morning)
        return .result()
    }
}

/// The Done button on the evening routine's widget.
struct CompleteEveningStepIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark Current Evening Habit Done"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background

    @Dependency private var actions: RoutineActions

    func perform() async throws -> some IntentResult {
        _ = try await actions.completeCurrent(.evening)
        return .result()
    }
}

#if os(iOS)
// Runs the widget's Done buttons in the app, not the widget extension.
//
// Apple documents that an intent conforming to `LiveActivityIntent` runs in the app's
// process. That is borrowed here for the routing alone, since there is no Live Activity. It
// keeps the widget read only: the tick goes through the app's own store, which is the only
// process that syncs, instead of a second writable container opened from an extension.
// watchOS has no such protocol, and a complication has no buttons to need it.
extension CompleteMorningStepIntent: LiveActivityIntent {}
extension CompleteEveningStepIntent: LiveActivityIntent {}
#endif

/// Answers what comes next, without opening anything.
struct NextHabitIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Next"
    static let description = IntentDescription("Says the next habit in a routine and how many are left.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Routine")
    var routine: RoutineChoice?

    @Dependency private var actions: RoutineActions

    init() {}

    static var parameterSummary: some ParameterSummary {
        Summary("What's next in the \(\.$routine) routine")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String?> {
        let glance = try await actions.glance()
        let slot = routine?.slot ?? glance.featured(at: .now, in: .current)
        let state = glance.routine(slot)
        return .result(value: state.nextHabitTitle, dialog: IntentDialog(stringLiteral: state.spoken))
    }
}

// MARK: - What Siri says

nonisolated extension StepOutcome {
    func spoken(for routine: RoutineSlot) -> String {
        let name = routine.title.lowercased()
        switch self {
        case .completed(let done, let next?, let remaining):
            let left = remaining == 1 ? "1 left" : "\(remaining) left"
            return "\(done) done. Next is \(next), \(left)."
        case .completed(let done, nil, _):
            return "\(done) done. That's your \(name) routine finished."
        case .nothingLeft:
            return "Your \(name) routine is already done for today."
        case .nothingDue:
            return "Nothing is due in your \(name) routine today."
        }
    }
}

nonisolated extension RoutineGlance {
    var spoken: String {
        let name = routine.title.lowercased()
        guard let next = nextHabitTitle else {
            return hasWorkToday
                ? "Your \(name) routine is done for today."
                : "Nothing is due in your \(name) routine today."
        }
        let left = remaining == 1 ? "It's the last one." : "\(remaining) left, including this one."
        return "Next in your \(name) routine is \(next). \(left)"
    }
}
