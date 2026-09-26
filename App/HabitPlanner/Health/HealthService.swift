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

    nonisolated struct Medication: Identifiable, Hashable, Sendable {
        /// What a binding stores to find this medication again. See `key(for:)`.
        let id: String
        let name: String
    }

    /// A medication and HealthKit's live identifier for it, which dose queries need.
    ///
    /// The identifier is not `Sendable`, but it is immutable and only read, so it is carried
    /// out of the query's callback as it is.
    private nonisolated struct SharedMedication: @unchecked Sendable {
        let medication: Medication
        let concept: HKHealthConceptIdentifier
    }

    /// A readable key for a medication: the clinical codes Health attaches to it, or its name
    /// and form when it has none.
    ///
    /// Stored in place of the concept identifier itself. That identifier has no public
    /// initialiser and shows only its domain, which is "medication" for every drug. Links
    /// stored as its archive showed the same name for different drugs, so the key is built
    /// from what is readable, and the live identifier is looked up by it when needed.
    nonisolated static func key(for concept: HKMedicationConcept) -> String {
        let codes = concept.relatedCodings.map { "\($0.system)|\($0.code)" }.sorted()
        if !codes.isEmpty { return "codes:" + codes.joined(separator: ",") }
        return "name:\(concept.displayText)|\(concept.generalForm.rawValue)"
    }

    /// Whether `stored` is a key from `key(for:)`, rather than an archive from an older build.
    nonisolated static func isKey(_ stored: String?) -> Bool {
        stored?.hasPrefix("codes:") == true || stored?.hasPrefix("name:") == true
    }

    /// Asks which medications the person will share, then lists the ones they chose.
    ///
    /// Medications use per-object authorisation. Passing the medication type to the ordinary
    /// `requestAuthorization` throws, which is sometimes misread as a hidden entitlement.
    ///
    /// The prompt appears only the first time. Found on a device: after that the call returns
    /// at once, and a medication not shared then can only be shared from Health itself. The
    /// picker says so and offers to open Health.
    func requestMedicationAccess() async throws -> [Medication] {
        try await store.requestPerObjectReadAuthorization(for: HKObjectType.userAnnotatedMedicationType(),
                                                          predicate: nil)
        return try await sharedMedications()
    }

    func sharedMedications() async throws -> [Medication] {
        try await shared().map(\.medication)
    }

    /// The shared medication a binding points at, with its live identifier.
    ///
    /// A binding from an older build holds an archived identifier, matched by equality rather
    /// than by its bytes, and used as it is if the medication is no longer shared.
    private func sharedMedication(for stored: String?) async throws -> SharedMedication? {
        let all = try await shared()
        if Self.isKey(stored) { return all.first { $0.medication.id == stored } }
        guard let archived = Self.unarchive(stored) else { return nil }
        return all.first { $0.concept == archived }
            ?? SharedMedication(medication: Medication(id: stored ?? "", name: "Medication"), concept: archived)
    }

    private func shared() async throws -> [SharedMedication] {
        let collector = MedicationCollector()
        return try await withCheckedThrowingContinuation { continuation in
            collector.continuation = continuation
            let query = HKUserAnnotatedMedicationQuery(predicate: nil, limit: HKObjectQueryNoLimit) {
                _, medication, done, error in
                collector.receive(medication, done: done, error: error)
            }
            store.execute(query)
        }
    }

    /// Gathers the query's callbacks and resumes the caller exactly once.
    ///
    /// The header promises a final callback with `done` set, and says nothing about whether an
    /// error ends the sequence. Resuming on the error and again on `done` would crash, so the
    /// first terminal callback wins and anything after it is ignored.
    private nonisolated final class MedicationCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var found: [SharedMedication] = []
        var continuation: CheckedContinuation<[SharedMedication], any Error>?

        func receive(_ medication: HKUserAnnotatedMedication?, done: Bool, error: (any Error)?) {
            lock.lock()
            defer { lock.unlock() }
            guard let continuation else { return }
            if let error {
                self.continuation = nil
                continuation.resume(throwing: error)
                return
            }
            if let medication, !medication.isArchived {
                let concept = medication.medication
                found.append(SharedMedication(
                    medication: Medication(id: HealthService.key(for: concept),
                                           name: medication.nickname ?? concept.displayText),
                    concept: concept.identifier))
            }
            if done {
                self.continuation = nil
                continuation.resume(returning: found)
            }
        }
    }

    /// Reads a link stored by a build before `key(for:)`. Nothing writes this form any more.
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
            // An unshared medication is not an unreadable binding: the person may share it
            // again, and until then Health has nothing to say about it.
            guard let concept = try await sharedMedication(for: binding.externalIdentifier)?.concept else {
                if Self.isKey(binding.externalIdentifier) { return [] }
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
            return (try? await sharedMedication(for: binding.externalIdentifier))?.medication.name
                ?? "A medication no longer shared"
        }
    }
}
