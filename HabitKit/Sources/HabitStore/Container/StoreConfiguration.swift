import Foundation
import SwiftData

/// The identifiers the store needs from the app bundle.
///
/// Injected rather than hardcoded, because the CloudKit container identifier is derived from
/// the bundle identifier and that has not been settled yet. Changing it after a container
/// exists is awkward, and a constant compiled into this package would be the worst place to
/// discover that.
public struct StoreIdentifiers: Hashable, Sendable {

    /// Usually `iCloud.` followed by the bundle identifier.
    public let cloudKitContainerID: String

    /// The App Group the app and its widgets share a store through. `nil` outside a
    /// group-sharing build, which is only useful before widgets exist.
    public let appGroupID: String?

    public init(cloudKitContainerID: String, appGroupID: String? = nil) {
        self.cloudKitContainerID = cloudKitContainerID
        self.appGroupID = appGroupID
    }
}

/// Which process is opening the store, which is the only thing that decides whether it syncs.
public enum StoreRole: Hashable, Sendable {

    /// iPhone, iPad and Mac. A full CloudKit peer, reading and writing.
    case syncingApp

    /// Apple Watch. A local store that never contacts CloudKit. See `resolved(for:)`.
    case localApp

    /// A widget extension. Reads the shared store and must never write to it or sync it.
    case readOnlyWidget

    /// Everything a test needs and nothing a device does.
    case inMemory
}

/// Which platform is opening the store, as a value rather than a compilation condition.
///
/// A parameter rather than a bare `#if` so that the watch rule below is exercised by the test
/// suite on every run, on whatever machine happens to be running it. Behind `#if os(watchOS)`
/// alone, the most consequential rule in this architecture would have been verified only by
/// a build nobody runs tests against.
public enum StorePlatform: Hashable, Sendable {
    case watch
    case other

    public static var current: StorePlatform {
        #if os(watchOS)
        return .watch
        #else
        return .other
        #endif
    }
}

/// Builds the `ModelContainer` each platform is allowed to have.
///
/// One container, two configurations. The synced configuration replicates to the private
/// CloudKit database. The health configuration never leaves the device. A model type belongs
/// to exactly one of them, and SwiftData refuses to let a type appear in both, so the
/// boundary is enforced by the framework rather than by review.
public enum HabitStoreContainer {

    public static let syncedStoreName = "HabitStore"
    public static let healthStoreName = "HabitHealthStore"

    /// The role this process is actually allowed, which is not always the one it asked for.
    ///
    /// On watchOS a request to sync is downgraded to local, deliberately and silently. Apple
    /// has an acknowledged bug, FB17685611, where SwiftData with CloudKit terminates the
    /// watch app 30 to 60 seconds into a `WKExtendedRuntimeSession` once the iPhone is out of
    /// range. That is this app's core scenario: running a routine with the phone in another
    /// room. Watch sync has also been reported degrading to hours, or working only on the
    /// charger, because delivery is scheduled by a system daemon with no override available.
    ///
    /// The downgrade lives here rather than in a call site's `#if` so that no future call
    /// site can get it wrong. The watch bridges to the phone over WatchConnectivity instead.
    public static func resolved(for role: StoreRole, platform: StorePlatform = .current) -> StoreRole {
        guard platform == .watch else { return role }
        return role == .syncingApp ? .localApp : role
    }

    /// The configuration for the CloudKit-backed models.
    public static func syncedConfiguration(
        role: StoreRole,
        identifiers: StoreIdentifiers,
        platform: StorePlatform = .current
    ) -> ModelConfiguration {
        let role = resolved(for: role, platform: platform)
        let schema = Schema(HabitSchemaV1.synced, version: HabitSchemaV1.versionIdentifier)

        if role == .inMemory {
            return ModelConfiguration(
                syncedStoreName,
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        }

        let database: ModelConfiguration.CloudKitDatabase
        switch role {
        case .syncingApp:
            database = .private(identifiers.cloudKitContainerID)
        case .localApp, .readOnlyWidget, .inMemory:
            // A widget opening a second syncing container against the same store has been
            // reported to lose data. It reads what the app already synced.
            database = .none
        }

        return ModelConfiguration(
            syncedStoreName,
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: role != .readOnlyWidget,
            groupContainer: identifiers.appGroupID.map { .identifier($0) } ?? .automatic,
            cloudKitDatabase: database
        )
    }

    /// The configuration for the models that never reach iCloud.
    ///
    /// `.none` on every platform, with no role able to change that. It is also kept out of
    /// the App Group: widgets have no use for a health binding, and the narrower the file is
    /// shared, the less there is to get wrong later.
    public static func healthConfiguration(
        role: StoreRole,
        platform: StorePlatform = .current
    ) -> ModelConfiguration {
        let schema = Schema(HabitSchemaV1.localHealth, version: HabitSchemaV1.versionIdentifier)

        if resolved(for: role, platform: platform) == .inMemory {
            return ModelConfiguration(
                healthStoreName,
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        }

        return ModelConfiguration(
            healthStoreName,
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            cloudKitDatabase: .none
        )
    }

    /// Opens the store for this process.
    public static func container(
        role: StoreRole,
        identifiers: StoreIdentifiers = StoreIdentifiers(cloudKitContainerID: ""),
        platform: StorePlatform = .current
    ) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(HabitSchemaV1.models, version: HabitSchemaV1.versionIdentifier),
            migrationPlan: HabitMigrationPlan.self,
            configurations: syncedConfiguration(role: role, identifiers: identifiers, platform: platform),
            healthConfiguration(role: role, platform: platform)
        )
    }
}
