import Foundation
import HabitStore
import SwiftData

/// Which store this launch opens.
///
/// Always the syncing store in a normal launch. The in-memory mode exists for the simulator
/// and for screenshots, and is reachable only through a launch argument in a debug build, so a
/// shipping build cannot end up writing somewhere other than the store it syncs.
enum StoreMode: Equatable {
    case syncing
    case inMemory(seeded: Bool)

    static var current: StoreMode {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-InMemoryStore") {
            return .inMemory(seeded: arguments.contains("-SeedDemoData"))
        }
        #endif
        return .syncing
    }

    var syncs: Bool { self == .syncing }

    func makeContainer() throws -> ModelContainer {
        switch self {
        case .syncing:
            try Self.prepareGroupContainer()
            return try HabitStoreContainer.container(role: .syncingApp, identifiers: AppIdentifiers.store)
        case .inMemory:
            return try HabitStoreContainer.container(role: .inMemory)
        }
    }

    /// Creates the directory SwiftData puts a group-container store in.
    ///
    /// A fresh App Group container has no `Library/Application Support`, and SwiftData does not
    /// create it. The first open fails, Core Data logs a sandbox denial, then a recovery path
    /// creates the folder and retries. Observed working on the simulator, but that is an
    /// undocumented fallback standing between the app and its only store, so it is not relied on.
    private static func prepareGroupContainer() throws {
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup
        ) else { return }
        let directory = group.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
