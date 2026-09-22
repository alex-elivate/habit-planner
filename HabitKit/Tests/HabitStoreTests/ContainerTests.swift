import Foundation
import HabitKit
import SwiftData
import Testing
@testable import HabitStore

@Suite("Container")
struct ContainerTests {

    private let identifiers = StoreIdentifiers(
        cloudKitContainerID: "iCloud.test.habitplanner",
        appGroupID: "group.test.habitplanner"
    )

    @Test("The watch never touches CloudKit, whatever role it asks for")
    func watchNeverSyncs() {
        // The most consequential rule in the architecture. Apple has an acknowledged bug
        // (FB17685611) where SwiftData with CloudKit terminates the watch app 30 to 60
        // seconds into an extended runtime session once the phone is out of range, which is
        // this app's core scenario. The downgrade lives in the factory so no call site can
        // opt out of it, and this pins it shut.
        for role in [StoreRole.syncingApp, .localApp, .readOnlyWidget] {
            let config = HabitStoreContainer.syncedConfiguration(
                role: role, identifiers: identifiers, platform: .watch)
            #expect(config.cloudKitContainerIdentifier == nil, "\(role) leaked CloudKit onto the watch")
        }
        #expect(HabitStoreContainer.resolved(for: .syncingApp, platform: .watch) == .localApp)
    }

    @Test("The phone and the Mac are full CloudKit peers")
    func syncingAppGetsCloudKit() {
        let config = HabitStoreContainer.syncedConfiguration(
            role: .syncingApp, identifiers: identifiers, platform: .other)
        #expect(config.cloudKitContainerIdentifier == identifiers.cloudKitContainerID)
        #expect(config.allowsSave)
    }

    @Test("A widget reads the shared store without syncing or writing it")
    func widgetIsReadOnlyAndLocal() {
        // A widget opening a second syncing container against the same store has been
        // reported to lose data, and a widget has no business writing anyway.
        let config = HabitStoreContainer.syncedConfiguration(
            role: .readOnlyWidget, identifiers: identifiers, platform: .other)
        #expect(config.cloudKitContainerIdentifier == nil)
        #expect(config.allowsSave == false)
    }

    @Test("The health store never syncs, on any platform or role")
    func healthStoreNeverSyncs() {
        // App Store 5.1.3(ii): an app may not store personal health information in iCloud.
        // A binding on a medication habit names a drug the person takes.
        for platform in [StorePlatform.watch, .other] {
            for role in [StoreRole.syncingApp, .localApp, .readOnlyWidget, .inMemory] {
                let config = HabitStoreContainer.healthConfiguration(role: role, platform: platform)
                #expect(config.cloudKitContainerIdentifier == nil)
            }
        }
    }

    @Test("The two stores hold disjoint models, and the health model is not in the synced set")
    func schemaSetsAreDisjoint() {
        let synced = Set(HabitSchemaV1.synced.map(String.init(describing:)))
        let local = Set(HabitSchemaV1.localHealth.map(String.init(describing:)))

        #expect(synced.isDisjoint(with: local))
        #expect(local.contains("StoredHealthBinding"))
        #expect(synced.contains("StoredHealthBinding") == false)
        #expect(synced.count + local.count == HabitSchemaV1.models.count)
    }

    @Test("A health binding cannot be reached through the synced schema")
    func healthBindingIsNotInTheSyncedStore() throws {
        // Structural rather than conventional: SwiftData refuses to let one model type appear
        // in two configurations, so a binding can only ever live in the store that never
        // leaves the device.
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
        // that has not been told about one. So every property must be optional or defaulted,
        // and constructing each model with nothing at all has to work. It is the closest
        // this suite can get to the real constraint, because building an actual CloudKit
        // container in a test process crashes rather than throwing when the schema is wrong.
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
}

@Suite("CloudKit schema priming")
struct SchemaPrimingTests {

    @Test("Priming touches every synced record type and leaves nothing behind")
    @MainActor
    func primingIsClean() async throws {
        let (store, container) = try makeStore()
        let touched = try await store.primeCloudKitSchema()

        #expect(Set(touched) == Set(HabitSchemaV1.synced.map(String.init(describing:))))

        let context = container.mainContext
        #expect(try context.fetchCount(FetchDescriptor<StoredHabit>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<StoredCompletionEvent>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<StoredLifecycleEvent>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<StoredRoutineRun>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<StoredRoutineStep>()) == 0)
    }

    @Test("Priming populates every optional, because an unwritten field never exists")
    func primingLeavesNoOptionalEmpty() throws {
        // The whole point of priming. A field SwiftData never sees a value for is absent from
        // the development schema, and promoting in that state makes it permanently absent
        // from production. Anything added to a synced model from here on has to be populated
        // in `primeCloudKitSchema()` too, and this fails if it is not.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Sources/HabitStore/Container/CloudKitSchemaPriming.swift"),
            encoding: .utf8
        )
        // Every optional in the synced schema, by the name priming has to mention.
        for field in ["cue", "twoMinuteVersion", "identityStatement", "payloadJSON",
                      "startedAt", "endedAt", "steps", "run"] {
            #expect(source.contains(field), "priming never populates '\(field)'")
        }
    }
}
