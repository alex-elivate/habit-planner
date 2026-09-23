import HabitStore

/// The one place the app's registered identifiers are written down.
///
/// All three are permanent once used. The CloudKit container in particular can never be deleted
/// or renamed, which is why `HabitStore` takes these as a parameter rather than compiling them
/// in, and refuses to open a syncing store without them.
enum AppIdentifiers {
    static let cloudKitContainer = "iCloud.org.trusler.habitplanner"
    static let appGroup = "group.org.trusler.habitplanner"

    static let store = StoreIdentifiers(cloudKitContainerID: cloudKitContainer, appGroupID: appGroup)
}
