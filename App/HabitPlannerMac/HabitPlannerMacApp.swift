import AppIntents
import AppKit
import HabitKit
import HabitStore
import Observation
import SwiftUI

@main
struct HabitPlannerMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @State private var launch = MacLaunch()

    var body: some Scene {
        WindowGroup {
            switch launch.state {
            case .ready(let model):
                MacRootView()
                    .environment(model)
                    .environment(MacRouter.shared)
                    .frame(minWidth: 760, minHeight: 480)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Your habits could not be opened", systemImage: "exclamationmark.icloud")
                } description: {
                    Text("Nothing has been written. Check that you are signed in to iCloud, then open the app again.")
                    Text(message).font(.footnote.monospaced()).foregroundStyle(.secondary)
                }
                .frame(minWidth: 480, minHeight: 320)
            }
        }
        .commands { MacCommands() }
    }
}

/// Opens the store once, and keeps the reason if it could not.
///
/// The Mac is a full CloudKit peer, like the phone: the same syncing store in the same App
/// Group, and no fallback to a local store if it fails. It has no Health, no reminders of its
/// own, since the phone's already reach the person, and no watch bridge.
@Observable
final class MacLaunch {
    enum State {
        case ready(AppModel)
        case failed(String)
    }

    let state: State

    init() {
        let mode = StoreMode.current
        do {
            let container = try mode.makeContainer()
            let model = AppModel(store: HabitStoreActor(modelContainer: container), mode: mode)
            state = .ready(model)
            AppDependencyManager.shared.add(dependency: RoutineActions(model: model) { routine in
                MacRouter.shared.requestedRoutine = routine
            })
            model.observeRemoteChanges()
            #if DEBUG
            if mode.isSeeded {
                Task {
                    if (try? await model.store.loadHabits().values.isEmpty) == true {
                        await DemoData.seed(into: model.store, timeZone: model.timeZone)
                    }
                    await model.reload()
                }
            }
            #endif
        } catch {
            state = .failed(String(describing: error))
            AppDependencyManager.shared.add(dependency: RoutineActions.unavailable)
        }
    }
}

/// Carries a request to start a routine, from Siri, a widget or a menu, to the window.
@Observable
final class MacRouter {
    static let shared = MacRouter()
    var requestedRoutine: RoutineSlot?
}

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // CloudKit delivers changes from other devices as silent pushes.
        NSApplication.shared.registerForRemoteNotifications()
    }

    /// One window is the whole app. Closing it quits, as it would for a single-window utility.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct MacCommands: Commands {
    var body: some Commands {
        // One window is the whole app, so there is no New Window. That also frees Command-N
        // for adding a habit.
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Routine") {
            Button("Start Morning Routine") { MacRouter.shared.requestedRoutine = .morning }
                .keyboardShortcut("1", modifiers: .command)
            Button("Start Evening Routine") { MacRouter.shared.requestedRoutine = .evening }
                .keyboardShortcut("2", modifiers: .command)
        }
    }
}
