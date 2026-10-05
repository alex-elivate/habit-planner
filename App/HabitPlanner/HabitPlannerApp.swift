import AppIntents
import HabitKit
import HabitStore
import Observation
import SwiftUI
import UIKit
import UserNotifications

@main
struct HabitPlannerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var launch: Launch

    /// Opens the store and registers what the intents depend on here, not on first use.
    ///
    /// `@State` builds an `@Observable` value lazily, the first time a scene draws. Siri and
    /// the widget's Done button launch the app in the background with no scene, so a lazy
    /// launch never ran, and the intent failed to find its `RoutineActions`.
    init() {
        _launch = State(initialValue: Launch())
    }

    var body: some Scene {
        WindowGroup {
            switch launch.state {
            case .ready(let model):
                RootView()
                    .environment(model)
                    .environment(delegate.router)
                    .environment(launch.reminders)
                    .environment(launch.health)
                    .environment(launch.bridge)
            case .failed(let message):
                StoreFailureView(message: message)
            }
        }
    }
}

/// Opens the store once, and keeps the reason if it could not.
///
/// There is no fallback to a local store on failure. Quietly writing somewhere that does not
/// sync would look fine for weeks and then lose everything on the next device, so the failure
/// is shown instead.
@Observable
final class Launch {
    enum State {
        case ready(AppModel)
        case failed(String)
    }

    let state: State
    let reminders = ReminderSettings()
    let health = HealthService()
    /// `nil` in the in-memory mode. Demo habits sent to a watch would stay in its replica for
    /// good. See `StoreMode.bridges`.
    private(set) var bridge: PhoneBridge?

    init() {
        let mode = StoreMode.current
        do {
            let container = try mode.makeContainer()
            let model = AppModel(store: HabitStoreActor(modelContainer: container), mode: mode)
            state = .ready(model)
            let actions = RoutineActions(model: model) { routine in
                Router.shared.requestedRoutine = routine
            }
            // A tick from the widget or Siri runs with the app in the background. Held open
            // until iCloud has it, so it reaches the Mac without the app being opened.
            let held = RoutineActions(
                start: actions.start,
                completeCurrent: { routine in
                    let token = await CloudUploadHold.shared.begin()
                    do {
                        let outcome = try await actions.completeCurrent(routine)
                        let saved = if case .completed = outcome { true } else { false }
                        await CloudUploadHold.shared.finish(token, saved: saved)
                        return outcome
                    } catch {
                        await CloudUploadHold.shared.finish(token, saved: false)
                        throw error
                    }
                },
                glance: actions.glance
            )
            AppDependencyManager.shared.add(dependency: held)
            ReminderActions.shared.model = model
            ReminderActions.shared.settings = reminders
            if mode.bridges {
                let bridge = PhoneBridge(model: model)
                bridge.start()
                self.bridge = bridge
            }
            // After the bridge, which sets its own hook. Every reload, so a reminder whose
            // habit was done elsewhere loses its buttons.
            let previous = model.afterReload
            model.afterReload = { [weak model] in
                previous?()
                guard let model else { return }
                Task { await ReminderActions.pruneDelivered(model: model) }
            }
            #if DEBUG
            if mode.isSeeded {
                Task {
                    // Once only in the persistent local mode, which would otherwise gain a
                    // second copy of every demo habit on each launch.
                    if (try? await model.store.loadHabits().values.isEmpty) == true {
                        await DemoData.seed(into: model.store, timeZone: model.timeZone)
                    }
                    await model.reload()
                }
            }
            #endif
        } catch {
            state = .failed(String(describing: error))
            // Registered anyway. An intent reaching for a dependency nobody added would stop
            // the process, where this lets Siri say the habits could not be opened.
            AppDependencyManager.shared.add(dependency: RoutineActions.unavailable)
        }
    }
}

/// Carries a tapped reminder to the interface.
@Observable
final class Router {
    /// One per process. Siri's Start Routine reaches it from outside the view tree.
    static let shared = Router()

    /// The routine a reminder asked to show. The root view scrolls to it and clears this.
    var requestedRoutine: RoutineSlot?
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let router = Router.shared

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        ReminderActions.registerCategory()
        // CloudKit delivers changes from other devices as silent pushes.
        application.registerForRemoteNotifications()
        return true
    }

    /// The completion-handler form, called on the main thread.
    ///
    /// Found by `ReminderActionTests`: the `async` form returns on a background thread, and
    /// when the app is in the background UIKit stops it with an assertion, because it updates
    /// the app's snapshot on the way out. Pressing Done on the lock screen crashed the app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let action = response.actionIdentifier
        let payload = ReminderActions.Payload(response.notification.request.content.userInfo)
        Task { @MainActor in
            // Done and Skip work in the background. A tap on the reminder opens the routine.
            if action == ReminderActions.doneAction || action == ReminderActions.skipAction {
                await ReminderActions.shared.handle(action, payload: payload)
            } else {
                router.requestedRoutine = payload.routine.flatMap(RoutineSlot.init(rawValue:))
            }
            completionHandler()
        }
    }

    /// A reminder arriving while the app is open still shows, since it is the cue to start.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

struct StoreFailureView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Your habits could not be opened", systemImage: "exclamationmark.icloud")
        } description: {
            Text("Nothing has been written. Check that you are signed in to iCloud, then open the app again.")
            Text(message).font(.footnote.monospaced()).foregroundStyle(.secondary)
        }
    }
}
