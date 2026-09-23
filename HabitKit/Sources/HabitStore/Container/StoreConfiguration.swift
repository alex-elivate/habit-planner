import Foundation
import SwiftData

/// Why a store could not be opened.
public enum StoreConfigurationError: Error, CustomStringConvertible {
    /// A syncing role was asked for without a CloudKit container identifier.
    case missingCloudKitContainerID

    public var description: String {
        switch self {
        case .missingCloudKitContainerID:
            return "A syncing store needs a CloudKit container identifier. Pass StoreIdentifiers explicitly."
        }
    }
}

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
/// CloudKit database. The health configuration never leaves the device.
///
/// **The framework does not enforce that split.** An earlier version of this comment claimed
/// SwiftData refuses to let one model type appear in two configurations. It does not: a
/// container built with `StoredHealthBinding` in both configurations is accepted, and a
/// binding saved through it persists without complaint.
///
/// So the only thing keeping a drug identifier out of iCloud is that `StoredHealthBinding`
/// is absent from `HabitSchemaV1.synced`. That is a convention with tests behind it, not a
/// guarantee, and the tests have to be the kind that would actually notice. Anyone moving a
/// model between those two arrays is making an App Store 5.1.3(ii) decision.
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
        #if os(watchOS)
        // A hard floor underneath the parameter. `platform` exists so the rule can be tested
        // from a Mac, and a default argument is overridable, so a watch build could pass
        // `.other` and reach CloudKit. On an actual watch there is no such thing as a
        // non-watch platform, and this makes that unarguable.
        if role == .syncingApp { return .localApp }
        #endif
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
    /// `.none` on every platform, with no role able to change that.
    ///
    /// `groupContainer` is passed explicitly rather than left to default. Omitting it means
    /// `.automatic`, which inspects entitlements and quietly moves the store *into* the App
    /// Group as soon as one ships for widget sharing. That would put a stored drug
    /// identifier in the container the widget extension can read, which is the opposite of
    /// what this store is for. Widgets have no use for a binding.
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
            allowsSave: role != .readOnlyWidget,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
    }

    /// Opens the store for this process.
    public static func container(
        role: StoreRole,
        identifiers: StoreIdentifiers = StoreIdentifiers(cloudKitContainerID: ""),
        platform: StorePlatform = .current
    ) throws -> ModelContainer {
        // The default identifier is empty, and an empty CloudKit container name is accepted
        // silently by `ModelConfiguration`. This is the one call that brings the production
        // container into existence, so a forgotten argument here is a mistake that cannot be
        // taken back. Local and in-memory roles legitimately need no identifier.
        if resolved(for: role, platform: platform) == .syncingApp,
           identifiers.cloudKitContainerID.isEmpty {
            throw StoreConfigurationError.missingCloudKitContainerID
        }

        return try ModelContainer(
            for: Schema(HabitSchemaV1.models, version: HabitSchemaV1.versionIdentifier),
            migrationPlan: HabitMigrationPlan.self,
            configurations: syncedConfiguration(role: role, identifiers: identifiers, platform: platform),
            healthConfiguration(role: role, platform: platform)
        )
    }
}
