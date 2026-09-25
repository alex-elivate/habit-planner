import Foundation
import HabitKit
import SwiftData
import Testing
@testable import HabitStore

/// Whether a configuration is genuinely not syncing.
///
/// **Not** `cloudKitContainerIdentifier == nil`. That property is `nil` for `.none` *and* for
/// `.automatic`, so the obvious assertion stays green while the store syncs to iCloud, which
/// is the exact failure both of these rules exist to prevent. `.automatic` is also what you
/// get by omitting the argument, so a refactor that drops `cloudKitDatabase:` enables it.
///
/// `CloudKitDatabase` is only `Sendable`, not `Equatable`, so the comparison goes through the
/// description against the canonical value rather than matching a substring. If Apple ever
/// changes that format, `noSyncCanaryStillDistinguishes` fails rather than this quietly
/// returning true for everything.
private func isNotSyncing(_ config: ModelConfiguration) -> Bool {
    String(describing: config.cloudKitDatabase)
        == String(describing: ModelConfiguration.CloudKitDatabase.none)
}

@Suite("Container")
struct ContainerTests {

    private let identifiers = StoreIdentifiers(
        cloudKitContainerID: "iCloud.test.habitplanner",
        appGroupID: "group.test.habitplanner"
    )

    @Test("The no-sync check can actually tell .none from .automatic")
    func noSyncCanaryStillDistinguishes() {
        // The canary for every assertion below. If these two ever describe identically, the
        // helper silently passes everything and both sync rules become unguarded.
        let none = ModelConfiguration("n", schema: Schema([StoredHealthBinding.self]),
                                      isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let auto = ModelConfiguration("a", schema: Schema([StoredHealthBinding.self]),
                                      isStoredInMemoryOnly: true, cloudKitDatabase: .automatic)
        #expect(isNotSyncing(none))
        #expect(isNotSyncing(auto) == false)
        // And the property that looks like it would work, demonstrably does not.
        #expect(none.cloudKitContainerIdentifier == auto.cloudKitContainerIdentifier)
    }

    @Test("The watch never touches CloudKit, whatever role it asks for")
    func watchNeverSyncs() {
        // Apple has an acknowledged bug (FB17685611) where SwiftData with CloudKit terminates
        // the watch app 30 to 60 seconds into an extended runtime session once the phone is
        // out of range, which is this app's core scenario.
        for role in [StoreRole.syncingApp, .localApp, .readOnlyWidget] {
            let config = HabitStoreContainer.syncedConfiguration(
                role: role, identifiers: identifiers, platform: .watch)
            #expect(isNotSyncing(config), "\(role) leaked CloudKit onto the watch")
        }
        #expect(HabitStoreContainer.resolved(for: .syncingApp, platform: .watch) == .localApp)
    }

    @Test("The phone and the Mac are full CloudKit peers")
    func syncingAppGetsCloudKit() {
        let config = HabitStoreContainer.syncedConfiguration(
            role: .syncingApp, identifiers: identifiers, platform: .other)
        #expect(config.cloudKitContainerIdentifier == identifiers.cloudKitContainerID)
        #expect(isNotSyncing(config) == false)
        #expect(config.allowsSave)
    }

    @Test("A widget reads the shared store without syncing or writing it")
    func widgetIsReadOnlyAndLocal() {
        let config = HabitStoreContainer.syncedConfiguration(
            role: .readOnlyWidget, identifiers: identifiers, platform: .other)
        #expect(isNotSyncing(config))
        #expect(config.allowsSave == false)
    }

    @Test("The health store never syncs, on any platform or role")
    func healthStoreNeverSyncs() {
        // App Store 5.1.3(ii): an app may not store personal health information in iCloud.
        // A binding on a medication habit names a drug the person takes.
        for platform in [StorePlatform.watch, .other] {
            for role in [StoreRole.syncingApp, .localApp, .readOnlyWidget, .inMemory] {
                let config = HabitStoreContainer.healthConfiguration(role: role, platform: platform)
                #expect(isNotSyncing(config), "health store synced for \(role) on \(platform)")
            }
        }
    }

    @Test("The health store stays out of the App Group and a widget cannot write it")
    func healthStoreIsPrivateToTheApp() {
        // Omitting `groupContainer` means `.automatic`, which moves the store into the App
        // Group once one ships for widget sharing. That would put a drug identifier in the
        // container the widget extension can read.
        let config = HabitStoreContainer.healthConfiguration(role: .syncingApp, platform: .other)
        #expect(String(describing: config.groupContainer)
                == String(describing: ModelConfiguration.GroupContainer.none))

        let widget = HabitStoreContainer.healthConfiguration(role: .readOnlyWidget, platform: .other)
        #expect(widget.allowsSave == false)
    }

    @Test("A syncing container refuses to open without a CloudKit identifier")
    func syncingContainerNeedsAnIdentifier() {
        // An empty container name is accepted silently by ModelConfiguration, and this is the
        // one call that brings the production container into existence.
        #expect(throws: StoreConfigurationError.self) {
            _ = try HabitStoreContainer.container(role: .syncingApp, platform: .other)
        }
        // Local roles legitimately need none.
        #expect(throws: Never.self) {
            _ = try HabitStoreContainer.container(role: .inMemory, platform: .other)
        }
    }

    @Test("The two stores hold disjoint models, and the health model is not in the synced set")
    func schemaSetsAreDisjoint() {
        // This is the whole PHI boundary. The framework does NOT enforce it: a container with
        // one model type in two configurations builds fine and saves fine. These two arrays
        // are the guarantee, so this test is the guarantee.
        let synced = Set(HabitSchemaV1.synced.map(String.init(describing:)))
        let local = Set(HabitSchemaV1.localHealth.map(String.init(describing:)))

        #expect(synced.isDisjoint(with: local))
        #expect(local == ["StoredHealthBinding"])
        #expect(synced.contains("StoredHealthBinding") == false)
        #expect(synced.count + local.count == HabitSchemaV1.models.count)
    }

    @Test("A health binding cannot be reached through the synced schema")
    func healthBindingIsNotInTheSyncedStore() throws {
        let syncedOnly = Schema(HabitSchemaV1.synced, version: HabitSchemaV1.versionIdentifier)
        let names = Set(syncedOnly.entities.map(\.name))
        #expect(names.contains("StoredHealthBinding") == false)
        #expect(names.contains("StoredCompletionEvent"))
    }

    @Test("The schema version is what records stamp themselves with")
    func schemaVersionIsConsistent() {
        #expect(HabitSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(StoredHabit(habitID: UUID()).schemaVersion == 1)
        #expect(StoredCompletionEvent().schemaVersion == 1)
        #expect(HabitMigrationPlan.schemas.count == 1)
    }

    @Test("Every synced model is readable with no field set")
    @MainActor
    func syncedModelsSurviveAnEmptyRecord() throws {
        // CloudKit cannot express a required field: a record can always arrive from a peer
        // that has not been told about one. Building an actual CloudKit container to check
        // this is not an option — it terminates the test process rather than throwing.
        let container = try makeContainer()
        let context = container.mainContext

        context.insert(StoredHabit())
        context.insert(StoredCompletionEvent())
        context.insert(StoredLifecycleEvent())
        context.insert(StoredRoutineRun())
        context.insert(StoredRoutineStep())
        context.insert(StoredHealthBinding())

        #expect(throws: Never.self) { try context.save() }
    }

    @Test("Every synced model's CloudKit shape is legal")
    func syncedModelsAreCloudKitLegal() {
        // Read off SwiftData's own schema metadata rather than by eye. A synced model may
        // have no unique attribute, no inheritance, and every property optional or defaulted.
        let schema = Schema(HabitSchemaV1.synced, version: HabitSchemaV1.versionIdentifier)
        for entity in schema.entities {
            #expect(entity.uniquenessConstraints.isEmpty, "\(entity.name) has a unique constraint")
            #expect(entity.superentityName == nil, "\(entity.name) uses inheritance")
            for relationship in entity.relationships {
                #expect(relationship.isOptional, "\(entity.name).\(relationship.name) is not optional")
                #expect(relationship.inverseName != nil, "\(entity.name).\(relationship.name) has no inverse")
                #expect(relationship.deleteRule != .deny, "\(entity.name).\(relationship.name) uses .deny")
            }
        }
    }
}

@Suite("CloudKit schema priming")
struct SchemaPrimingTests {

    /// Every optional column in the synced schema, derived from SwiftData at runtime.
    ///
    /// This is what replaced a test that read its own source file and string-matched eight
    /// hardcoded names. That version passed when a field was genuinely missing: adding an
    /// unprimed `reminderSoundName` to `StoredHabit` left the whole suite green, which is
    /// precisely the failure priming exists to prevent.
    private func optionalColumns() -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        let schema = Schema(HabitSchemaV1.synced, version: HabitSchemaV1.versionIdentifier)
        for entity in schema.entities {
            result[entity.name] = Set(entity.properties.filter(\.isOptional).map(\.name))
        }
        return result
    }

    @Test("The set of optional columns is exactly what priming knows about")
    func optionalColumnsAreAccountedFor() {
        // Derived from the schema, compared against an explicit list. Add an optional to any
        // synced model and this fails immediately, which forces whoever added it to look at
        // `CloudKitSchemaPriming.records()` and at the value assertions below.
        //
        // A field SwiftData never sees a value for does not exist in the development schema,
        // and is therefore permanently absent from production once promoted.
        let expected: [String: Set<String>] = [
            "StoredHabit": ["cue", "twoMinuteVersion", "identityStatement", "payloadJSON"],
            "StoredCompletionEvent": ["payloadJSON"],
            "StoredLifecycleEvent": ["payloadJSON"],
            "StoredRoutineRun": ["startedAt", "endedAt", "steps", "payloadJSON"],
            "StoredRoutineStep": ["startedAt", "endedAt", "run", "payloadJSON"],
            "StoredPlannedHabit": ["payloadJSON"]
        ]
        #expect(optionalColumns() == expected)
    }

    @Test("Priming populates every optional column")
    func primingPopulatesEveryOptional() {
        // Explicit because reflection cannot do this: a @Model's stored properties live in
        // `_$backingData`, and `Mirror` reports `_SwiftDataNoType()` for non-optionals and
        // `nil` for optionals whatever they were set to. The list above is what keeps this
        // list honest.
        let r = CloudKitSchemaPriming.records()

        #expect(r.habit.cue != nil)
        #expect(r.habit.twoMinuteVersion != nil)
        #expect(r.habit.identityStatement != nil)
        #expect(r.habit.payloadJSON != nil)

        #expect(r.completion.payloadJSON != nil)
        #expect(r.lifecycle.payloadJSON != nil)

        #expect(r.run.startedAt != nil)
        #expect(r.run.endedAt != nil)
        #expect(r.run.payloadJSON != nil)

        #expect(r.step.startedAt != nil)
        #expect(r.step.endedAt != nil)
        #expect(r.step.run != nil)
        #expect(r.step.payloadJSON != nil)

        #expect(r.planned.payloadJSON != nil)
    }

    @Test("Priming exercises the relationship and leaves nothing behind")
    @MainActor
    func primingIsCleanAndExercisesTheRelationship() async throws {
        let (store, container) = try makeStore()
        let touched = try await store.primeCloudKitSchema()
        #expect(Set(touched) == Set(HabitSchemaV1.synced.map(String.init(describing:))))

        let context = container.mainContext
        #expect(try context.fetchCount(FetchDescriptor<StoredHabit>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<StoredCompletionEvent>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<StoredLifecycleEvent>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<StoredRoutineRun>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<StoredRoutineStep>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<StoredPlannedHabit>()) == 0)
    }
}
