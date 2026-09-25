import HabitKit
import HabitStore
import Observation
import SwiftUI
import UserNotifications
import WatchKit

@main
struct HabitPlannerWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @State private var launch = WatchLaunch()

    var body: some Scene {
        WindowGroup {
            switch launch.state {
            case .ready(let model):
                WatchRootView()
                    .environment(model)
                    .environment(launch.bridge)
                    .environment(delegate.router)
            case .failed(let message):
                ScrollView {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.title2)
                        Text("Your habits could not be opened").font(.headline)
                        Text(message).font(.footnote.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Opens the watch's store once, and keeps the reason if it could not.
///
/// Always a local store. `HabitStoreContainer` downgrades any request to sync on watchOS
/// anyway, but asking for `.localApp` says what is meant.
///
/// The store lives in the watch's App Group container, where the complication can read it.
/// Phase 4 kept it in the app's own container. No build of that ever ran on a real watch, so
/// there is no store in the old place to carry over, and a replica can be rebuilt from the
/// phone's next snapshot in any case, except for writes not yet reported.
@Observable
final class WatchLaunch {
    enum State {
        case ready(WatchModel)
        case failed(String)
    }

    let state: State
    /// `nil` in the in-memory mode, so demo habits never reach the phone and, through it,
    /// CloudKit.
    private(set) var bridge: WatchBridge?

    init() {
        var inMemory = false
        var seeded = false
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        inMemory = arguments.contains("-InMemoryStore")
        seeded = inMemory && arguments.contains("-SeedDemoData")
        #endif

        do {
            if !inMemory {
                // A fresh group container has no Application Support folder, and SwiftData
                // does not create it. The first open then fails and only succeeds through Core
                // Data's undocumented recovery path. The bridge's own files still live in the
                // app's container, so that folder is made too.
                try AppIdentifiers.prepareGroupContainer()
                try FileManager.default.createDirectory(at: .applicationSupportDirectory,
                                                        withIntermediateDirectories: true)
            }
            let container = try HabitStoreContainer.container(
                role: inMemory ? .inMemory : .localApp,
                identifiers: StoreIdentifiers(cloudKitContainerID: "", appGroupID: AppIdentifiers.appGroup)
            )
            let model = WatchModel(store: HabitStoreActor(modelContainer: container),
                                   complicationsReadThisStore: !inMemory)
            state = .ready(model)
            if !inMemory {
                let bridge = WatchBridge(model: model)
                bridge.start()
                self.bridge = bridge
            }
            #if DEBUG
            if seeded {
                Task {
                    await DemoData.seed(into: model.store, timeZone: model.timeZone)
                    await model.reload()
                }
            }
            #endif
        } catch {
            state = .failed(String(describing: error))
        }
    }
}

/// Carries a tapped reminder to the interface.
@Observable
final class WatchRouter {
    var requestedRoutine: RoutineSlot?
}

/// Receives the iPhone's routine reminders when they are forwarded to the wrist.
///
/// The watch schedules none of its own. The phone's reminder already reaches the watch when
/// the phone is locked, and a second one from the watch would arrive as a duplicate.
final class WatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    let router = WatchRouter()

    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let raw = response.notification.request.content.userInfo[RoutineSlot.notificationKey] as? String
        await MainActor.run {
            router.requestedRoutine = raw.flatMap(RoutineSlot.init(rawValue:))
        }
    }
}
