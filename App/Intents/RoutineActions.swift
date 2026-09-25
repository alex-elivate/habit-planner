import AppIntents
import HabitKit
import HabitStore

/// What an intent may ask of whichever app it runs in.
///
/// Registered by the iPhone app and the watch app at launch, each over its own model, so an
/// intent writes through exactly the path a tap in that app's runner does: the phone's syncing
/// store, or the watch's replica with the bridge told before and after.
///
/// The widget extension compiles the intents so its button can name one, and never registers
/// this. It does not have to: the one intent a widget runs conforms to `LiveActivityIntent`,
/// which Apple documents as running in the app's process, not the extension's.
nonisolated struct RoutineActions: Sendable {
    /// Brings the app forward on the runner for `routine`.
    var start: @Sendable (RoutineSlot) async -> Void
    /// Marks done the habit next in `routine`'s sequence.
    var completeCurrent: @Sendable (RoutineSlot) async throws -> StepOutcome
    /// The routines as they stand now.
    var glance: @Sendable () async throws -> Glance

    /// Registered when the store could not be opened, so an intent says so rather than
    /// reaching for a dependency that is not there.
    static let unavailable = RoutineActions(
        // The app is already showing why the store failed, which is the right thing to see.
        start: { _ in },
        completeCurrent: { _ in throw IntentFailure.storeUnavailable },
        glance: { throw IntentFailure.storeUnavailable }
    )
}

/// A model an intent can act through. Both apps' models conform, so each registers the same way.
@MainActor
protocol RoutineActing: AnyObject, Sendable {
    func completeCurrentStep(in routine: RoutineSlot) async throws -> StepOutcome
    func glanceNow() async throws -> Glance
}

nonisolated extension RoutineActions {
    /// The actions over `model`, with `start` handing the routine to the app's router.
    init(model: some RoutineActing, start: @escaping @Sendable @MainActor (RoutineSlot) -> Void) {
        self.init(
            start: { routine in await start(routine) },
            completeCurrent: { routine in try await model.completeCurrentStep(in: routine) },
            glance: { try await model.glanceNow() }
        )
    }
}

nonisolated enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case storeUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .storeUnavailable: "Habit Planner could not open your habits. Open the app to see why."
        }
    }
}
