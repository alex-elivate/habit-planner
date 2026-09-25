import Foundation
import HabitStore
import SwiftData

/// Which store this launch opens.
///
/// Always the syncing store in a normal launch. The in-memory mode exists for the simulator
/// and for screenshots, and is reachable only through a launch argument in a debug build, so a
/// shipping build cannot end up writing somewhere other than the store it syncs.
///
/// The local mode is a persistent store that does not sync, for exercising the watch bridge
/// between paired simulators. An unsigned simulator build has no iCloud entitlement, so it
/// cannot open the syncing store, and the in-memory mode never bridges. Debug only, like the
/// in-memory mode.
enum StoreMode: Equatable {
    case syncing
    case local(seeded: Bool)
    case inMemory(seeded: Bool)

    static var current: StoreMode {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-InMemoryStore") {
            return .inMemory(seeded: arguments.contains("-SeedDemoData"))
        }
        if arguments.contains("-LocalStore") {
            return .local(seeded: arguments.contains("-SeedDemoData"))
        }
        #endif
        return .syncing
    }

    var syncs: Bool { self == .syncing }

    /// Whether this store may exchange records with the watch. Never the in-memory store, whose
    /// demo habits would sit in the watch's replica for good.
    var bridges: Bool {
        if case .inMemory = self { return false }
        return true
    }

    var isSeeded: Bool {
        switch self {
        case .syncing: false
        case .local(let seeded), .inMemory(let seeded): seeded
        }
    }

    func makeContainer() throws -> ModelContainer {
        switch self {
        case .syncing:
            try AppIdentifiers.prepareGroupContainer()
            return try HabitStoreContainer.container(role: .syncingApp, identifiers: AppIdentifiers.store)
        case .local:
            // Outside the App Group, in the app's own Application Support, which a fresh
            // container lacks just as a fresh group does.
            try FileManager.default.createDirectory(at: .applicationSupportDirectory,
                                                    withIntermediateDirectories: true)
            return try HabitStoreContainer.container(role: .localApp)
        case .inMemory:
            return try HabitStoreContainer.container(role: .inMemory)
        }
    }
}
