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
            AppDependencyManager.shared.add(dependency: RoutineActions(model: model) { routine in
                Router.shared.requestedRoutine = routine
            })
            if mode.bridges {
                let bridge = PhoneBridge(model: model)
                bridge.start()
                self.bridge = bridge
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

    /// The routine a reminder asked to start. The root view presents it and clears this.
    var requestedRoutine: RoutineSlot?
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let router = Router.shared

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // CloudKit delivers changes from other devices as silent pushes.
        application.registerForRemoteNotifications()
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let raw = response.notification.request.content.userInfo[ReminderScheduler.routineKey] as? String
        await MainActor.run {
            router.requestedRoutine = raw.flatMap(RoutineSlot.init(rawValue:))
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
