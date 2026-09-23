import Foundation
import HabitKit
import HealthKit
import Observation

/// Reads the two signals this app can use: a workout of one type, and a dose of one medication
/// logged as taken.
///
/// Read-only by design, and not only because Apple makes medication doses read-only. Health
/// proposes, the app owns the record. Revoked read access returns an empty result that cannot
/// be told apart from "nothing happened", so nothing here may ever decide a habit was missed.
/// An empty answer means only that there is nothing to offer.
@Observable
final class HealthService {
    @ObservationIgnored private let store = HKHealthStore()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: - Workouts

    /// The activity types offered when linking a habit. Kept short on purpose: these are the
    /// ones a morning or evening routine plausibly contains.
    static let workoutChoices: [(name: String, type: HKWorkoutActivityType)] = [
        ("Walk", .walking),
        ("Run", .running),
        ("Cycle", .cycling),
        ("Yoga", .yoga),
        ("Strength training", .traditionalStrengthTraining),
        ("Mind and body", .mindAndBody),
        ("Swim", .swimming),
    ]

    static func workoutName(for rawValue: String?) -> String {
        guard let rawValue, let value = UInt(rawValue),
              let choice = workoutChoices.first(where: { $0.type.rawValue == value })
        else { return "Workout" }
        return choice.name
    }

    func requestWorkoutAccess() async throws {
        try await store.requestAuthorization(toShare: [], read: [HKObjectType.workoutType()])
    }

    // MARK: - Medications

    struct Medication: Identifiable, Hashable {
        /// The archived concept identifier. Opaque, and never shown.
        let id: String
        let name: String
    }

    /// Asks which medications the person will share, then lists the ones they chose.
    ///
    /// Medications use per-object authorisation. Passing the medication type to the ordinary
    /// `requestAuthorization` throws, which is sometimes misread as a hidden entitlement. The
    /// prompt always appears, even if access was granted before, because the person picks
    /// medications individually each time.
    func requestMedicationAccess() async throws -> [Medication] {
        try await store.requestPerObjectReadAuthorization(for: HKObjectType.userAnnotatedMedicationType(),
                                                          predicate: nil)
        return try await sharedMedications()
    }

    func sharedMedications() async throws -> [Medication] {
        try await withCheckedThrowingContinuation { continuation in
            var found: [Medication] = []
            let query = HKUserAnnotatedMedicationQuery(predicate: nil, limit: HKObjectQueryNoLimit) {
                _, medication, done, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let medication, !medication.isArchived,
                   let id = Self.archive(medication.medication.identifier) {
                    found.append(Medication(id: id, name: medication.nickname ?? medication.medication.displayText))
                }
                if done { continuation.resume(returning: found) }
            }
            store.execute(query)
        }
    }

    static func archive(_ identifier: HKHealthConceptIdentifier) -> String? {
        try? NSKeyedArchiver.archivedData(withRootObject: identifier, requiringSecureCoding: true)
            .base64EncodedString()
    }

    static func unarchive(_ string: String?) -> HKHealthConceptIdentifier? {
        guard let string, let data = Data(base64Encoded: string) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKHealthConceptIdentifier.self, from: data)
    }

    // MARK: - Signals

    enum SignalError: Error {
        case unavailable
        case unreadableBinding
    }

    /// Every instant in `interval` at which Health saw this binding's signal.
    ///
    /// For a workout that is its start, which is when the person would say they did it. For a
    /// medication it is the dose's own date, and only doses logged as taken count. Skipped and
    /// snoozed doses are the person telling Health they did not take it.
    func signalInstants(for binding: HealthBinding, in interval: DateInterval) async throws -> [Date] {
        guard isAvailable else { throw SignalError.unavailable }
        let during = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end,
                                                 options: .strictStartDate)
        switch binding.signal {
        case .workout:
            guard let raw = binding.externalIdentifier, let value = UInt(raw),
                  let activity = HKWorkoutActivityType(rawValue: value)
            else { throw SignalError.unreadableBinding }
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                during, HKQuery.predicateForWorkouts(with: activity),
            ])
            let workouts = try await HKSampleQueryDescriptor(
                predicates: [.workout(predicate)], sortDescriptors: [SortDescriptor(\.startDate)]
            ).result(for: store)
            return workouts.map(\.startDate)

        case .medication:
            guard let concept = Self.unarchive(binding.externalIdentifier) else {
                throw SignalError.unreadableBinding
            }
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                during,
                HKQuery.predicateForMedicationDoseEvent(medicationConceptIdentifier: concept),
                HKQuery.predicateForMedicationDoseEvent(status: .taken),
            ])
            let samples = try await HKSampleQueryDescriptor(
                predicates: [.sample(type: HKObjectType.medicationDoseEventType(), predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.startDate)]
            ).result(for: store)
            return samples.map(\.startDate)
        }
    }

    /// A name for what a binding watches, for the interface.
    func describe(_ binding: HealthBinding) async -> String {
        switch binding.signal {
        case .workout:
            return Self.workoutName(for: binding.externalIdentifier)
        case .medication:
            let medications = (try? await sharedMedications()) ?? []
            return medications.first { $0.id == binding.externalIdentifier }?.name ?? "Medication"
        }
    }
}
