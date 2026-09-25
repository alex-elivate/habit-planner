import Foundation
import HabitStore

/// The one place the app's registered identifiers are written down.
///
/// All three are permanent once used. The CloudKit container in particular can never be deleted
/// or renamed, which is why `HabitStore` takes these as a parameter rather than compiling them
/// in, and refuses to open a syncing store without them.
///
/// Shared by every target. The watch uses the same App Group identifier as the phone, which
/// names a separate container on each device, so the watch's store and its complication meet
/// in the watch's container and nothing crosses to the phone that way.
nonisolated enum AppIdentifiers {
    static let cloudKitContainer = "iCloud.org.trusler.habitplanner"
    static let appGroup = "group.org.trusler.habitplanner"

    static let store = StoreIdentifiers(cloudKitContainerID: cloudKitContainer, appGroupID: appGroup)

    /// Creates the directory SwiftData puts a group-container store in.
    ///
    /// A fresh App Group container has no `Library/Application Support`, and SwiftData does not
    /// create it. The first open fails, Core Data logs a sandbox denial, then a recovery path
    /// creates the folder and retries. Observed working on the simulator, but that is an
    /// undocumented fallback standing between the app and its only store, so it is not relied on.
    static func prepareGroupContainer() throws {
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else { return }
        let directory = group.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
