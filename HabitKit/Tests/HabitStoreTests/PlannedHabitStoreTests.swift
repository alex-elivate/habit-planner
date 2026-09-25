import Foundation
import HabitKit
import SwiftData
import Testing
@testable import HabitStore

private func t(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

@Suite("Planned habit store")
struct PlannedHabitStoreTests {

    @Test("A plan is read back, and a newer one replaces it in the same row")
    @MainActor
    func recordAndReplace() async throws {
        let (store, container) = try makeStore()
        #expect(try await store.record(PlannedHabit(routine: .morning, title: "Meditate", recordedAt: t(1))))
        #expect(try await store.record(PlannedHabit(routine: .morning, title: "Journal", recordedAt: t(2))))

        let loaded = try await store.loadPlannedHabits().values
        #expect(loaded == [PlannedHabit(routine: .morning, title: "Journal", recordedAt: t(2))])
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredPlannedHabit>()) == 1)
    }

    @Test("An older plan arriving late changes nothing")
    @MainActor
    func olderIsIgnored() async throws {
        let (store, _) = try makeStore()
        try await store.record(PlannedHabit(routine: .evening, title: "Floss", recordedAt: t(5)))
        #expect(try await store.record(PlannedHabit(routine: .evening, title: "Stretch", recordedAt: t(4))) == false)
        #expect(try await store.loadPlannedHabits().values.map(\.title) == ["Floss"])
    }

    @Test("Clearing keeps the row and empties it")
    @MainActor
    func clearKeepsTheRow() async throws {
        let (store, container) = try makeStore()
        try await store.record(PlannedHabit(routine: .evening, title: "Floss", recordedAt: t(1)))
        try await store.record(.cleared(.evening, at: t(2)))

        let resolved = try await store.loadPlannedHabits().values.resolved()
        #expect(resolved.active(for: .evening) == nil)
        #expect(resolved[.evening]?.isCleared == true)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredPlannedHabit>()) == 1)
    }

    @Test("Rows for one routine from two devices collapse on the next write, and resolve on read before it")
    @MainActor
    func duplicatesCollapse() async throws {
        let (store, container) = try makeStore()
        let context = container.mainContext
        // What CloudKit delivers when two devices each planned a morning habit.
        context.insert(StoredPlannedHabit(routineRaw: "morning", title: "Meditate", recordedAt: t(3)))
        context.insert(StoredPlannedHabit(routineRaw: "morning", title: "Journal", recordedAt: t(7)))
        try context.save()

        #expect(try await store.loadPlannedHabits().values.map(\.title) == ["Journal"])

        try await store.record(PlannedHabit(routine: .evening, title: "Floss", recordedAt: t(1)))
        #expect(try context.fetchCount(FetchDescriptor<StoredPlannedHabit>()) == 3,
                "A write to another routine must not touch this one")

        try await store.record(PlannedHabit(routine: .morning, title: "Journal", recordedAt: t(7)))
        let morning = try context.fetch(FetchDescriptor<StoredPlannedHabit>(
            predicate: #Predicate { $0.routineRaw == "morning" }))
        #expect(morning.count == 1)
        #expect(morning.first?.title == "Journal")
    }

    @Test("A plan written by a newer build is reported and left alone")
    @MainActor
    func newerRecordIsSkipped() async throws {
        let (store, container) = try makeStore()
        container.mainContext.insert(StoredPlannedHabit(routineRaw: "morning", title: "From the future",
                                                        recordedAt: t(1), schemaVersion: 99))
        try container.mainContext.save()

        let loaded = try await store.loadPlannedHabits()
        #expect(loaded.values.isEmpty)
        #expect(loaded.skipped.count == 1)
    }

    // MARK: - Through the watch bridge

    @Test("The watch receives the phone's plans, and a clear on the phone clears the watch")
    @MainActor
    func snapshotCarriesPlans() async throws {
        let (phone, _) = try makeStore()
        let (watch, _) = try makeStore()

        try await phone.record(PlannedHabit(routine: .morning, title: "Meditate", recordedAt: t(1)))
        try await watch.merge(try await phone.watchSnapshot(today: referenceToday, generatedAt: t(2)))
        #expect(try await watch.loadPlannedHabits().values.resolved().active(for: .morning)?.title == "Meditate")

        try await phone.record(.cleared(.morning, at: t(3)))
        let result = try await watch.merge(try await phone.watchSnapshot(today: referenceToday, generatedAt: t(4)))
        #expect(result.written == 1)
        #expect(try await watch.loadPlannedHabits().values.resolved().active(for: .morning) == nil)
    }

    @Test("A snapshot the watch already holds writes nothing, and a stale one cannot undo a clear")
    @MainActor
    func mergeIsIdempotentAndMonotonic() async throws {
        let (phone, _) = try makeStore()
        let (watch, _) = try makeStore()

        try await phone.record(PlannedHabit(routine: .evening, title: "Floss", recordedAt: t(1)))
        let stale = try await phone.watchSnapshot(today: referenceToday, generatedAt: t(2))
        try await phone.record(.cleared(.evening, at: t(3)))
        let fresh = try await phone.watchSnapshot(today: referenceToday, generatedAt: t(4))

        try await watch.merge(fresh)
        #expect(try await watch.merge(fresh).written == 0)
        #expect(try await watch.merge(stale).written == 0)
        #expect(try await watch.loadPlannedHabits().values.resolved().active(for: .evening) == nil)
    }
}

@Suite("Widget container")
struct WidgetContainerTests {

    @Test("A widget refuses to open without the App Group")
    func needsTheGroup() {
        // `.automatic` would open an empty store in the extension's own sandbox, and the widget
        // would show no habits for good.
        #expect(throws: StoreConfigurationError.missingAppGroupID) {
            _ = try HabitStoreContainer.container(
                role: .readOnlyWidget, identifiers: StoreIdentifiers(cloudKitContainerID: ""), platform: .other)
        }
    }

    @Test("A widget before the app's first launch fails to open rather than creating a store")
    func missingStoreIsAnError() throws {
        // Read only means the widget cannot create the file. It shows a placeholder until the
        // app has run, instead of an empty store of its own that would never fill.
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "HabitStore.store")

        #expect(throws: (any Error).self) {
            _ = try HabitStoreContainer.readOnlyContainer(ModelConfiguration(
                HabitStoreContainer.syncedStoreName,
                schema: Schema(HabitSchemaV1.synced, version: HabitSchemaV1.versionIdentifier),
                url: url, allowsSave: false, cloudKitDatabase: .none))
        }
        #expect(FileManager.default.fileExists(atPath: url.path()) == false)
    }

    @Test("A widget reads what the app wrote, from the same file, and cannot write to it")
    @MainActor
    func readsTheAppsStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let syncedURL = directory.appending(path: "HabitStore.store")

        // The app's container: both configurations, the synced one at a known file.
        let app = try ModelContainer(
            for: Schema(HabitSchemaV1.models, version: HabitSchemaV1.versionIdentifier),
            migrationPlan: HabitMigrationPlan.self,
            configurations:
                ModelConfiguration(HabitStoreContainer.syncedStoreName,
                                   schema: Schema(HabitSchemaV1.synced, version: HabitSchemaV1.versionIdentifier),
                                   url: syncedURL, cloudKitDatabase: .none),
                ModelConfiguration(HabitStoreContainer.healthStoreName,
                                   schema: Schema(HabitSchemaV1.localHealth, version: HabitSchemaV1.versionIdentifier),
                                   url: directory.appending(path: "HabitHealthStore.store"), cloudKitDatabase: .none)
        )
        let appStore = HabitStoreActor(modelContainer: app)
        let habit = sampleHabit()
        try await appStore.upsert(habit)
        try await appStore.record(completion(habit.id, referenceToday.advanced(by: -1)))
        try await appStore.record(PlannedHabit(routine: .morning, title: "Meditate", recordedAt: t(1)))

        let widget = try HabitStoreContainer.readOnlyContainer(ModelConfiguration(
            HabitStoreContainer.syncedStoreName,
            schema: Schema(HabitSchemaV1.synced, version: HabitSchemaV1.versionIdentifier),
            url: syncedURL, allowsSave: false, cloudKitDatabase: .none))
        let widgetStore = HabitStoreActor(modelContainer: widget)
        // One store only. Were the health model given a store of its own, it would be a
        // `default.store` in the extension's sandbox.
        #expect(widget.configurations.map(\.name) == [HabitStoreContainer.syncedStoreName])

        let histories = try await widgetStore.loadHistories(today: referenceToday)
        #expect(histories.values.map(\.habit.id) == [habit.id])
        #expect(histories.values.first?.settledOccurrences.filter(\.isCompleted).count == 1)
        #expect(try await widgetStore.loadPlannedHabits().values.map(\.title) == ["Meditate"])

        await #expect(throws: (any Error).self) {
            try await widgetStore.upsert(sampleHabit())
        }
    }
}
