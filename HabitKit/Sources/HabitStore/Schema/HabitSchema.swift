import Foundation
import SwiftData

/// Version 1 of the stored schema, and the two disjoint sets of models it splits into.
///
/// ### The split is the point
///
/// `synced` goes to CloudKit. `localHealth` never does. A model belongs to exactly one of
/// them, which is not a stylistic choice: SwiftData will not let the same type appear in two
/// configurations of one container, so the boundary is enforced by the framework rather than
/// by a comment.
///
/// ### When this freezes
///
/// The first promotion to the CloudKit production environment makes every record type and
/// field here permanent. Fields may be added afterwards. Nothing may be renamed or removed.
/// `initializeCloudKitSchema()` must therefore be run from a development build, and its
/// output reviewed in the dashboard, before any build reaches TestFlight.
public enum HabitSchemaV1: VersionedSchema {

    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    /// Replicated to the private CloudKit database on iPhone and Mac.
    ///
    /// No model here holds anything read out of HealthKit. A completion written after a
    /// health signal proposed it is the app's own record of a confirmation, not a copy of
    /// a health sample, which is what keeps it on this side of the line.
    public static var synced: [any PersistentModel.Type] {
        [
            StoredHabit.self,
            StoredCompletionEvent.self,
            StoredLifecycleEvent.self,
            StoredRoutineRun.self,
            StoredRoutineStep.self
        ]
    }

    /// Never leaves the device. See `StoredHealthBinding` for why this set exists at all.
    public static var localHealth: [any PersistentModel.Type] {
        [StoredHealthBinding.self]
    }

    public static var models: [any PersistentModel.Type] { synced + localHealth }
}

/// Migration plan for the stored schema.
///
/// Empty of stages at version 1, and present anyway. Adding the plan after the fact means
/// the first shipped store was opened without one, and retrofitting a migration path onto
/// records already replicated to other people's devices is the expensive kind of problem.
public enum HabitMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [HabitSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}
