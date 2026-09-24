import Foundation

/// What the iPhone sends the watch: every record the watch needs to fold for itself.
///
/// The watch keeps a full local replica rather than a summary. A summary would be derived
/// state, and a watch showing a streak computed on another device, at another moment, is the
/// same stored-aggregate hazard the whole domain is built to avoid. With the records it folds
/// with the same code as the phone and reaches the same answer.
///
/// A snapshot only ever adds. The phone never deletes a record, so a newer snapshot is always
/// a superset of an older one, and merging an older one late loses nothing. Health bindings
/// are not in it and have no field to go in: they name a drug and stay on the device that made
/// them.
public struct WatchSnapshot: Codable, Sendable {
    public static let currentFormat = 1

    public let format: Int
    public let generatedAt: Date
    public let habits: [Habit]
    /// Resolved on the phone, one per habit, day and slot. Merging folds them again, so
    /// sending the raw log instead would reach the same answer at a larger size.
    public let completions: [CompletionEvent]
    public let lifecycle: [LifecycleEvent]
    /// Recent runs only, so a routine started on one device can be resumed on the other.
    public let runs: [RoutineRun]

    public init(
        generatedAt: Date,
        habits: [Habit],
        completions: [CompletionEvent],
        lifecycle: [LifecycleEvent],
        runs: [RoutineRun]
    ) {
        self.format = Self.currentFormat
        self.generatedAt = generatedAt
        self.habits = habits
        self.completions = completions
        self.lifecycle = lifecycle
        self.runs = runs
    }
}

/// What the watch sends the iPhone: the records it holds for a trailing window of days.
///
/// Only completions and runs, because those are the only things the watch writes. It never
/// edits a habit or its lifecycle, and a report has no field that could carry one, so a stale
/// watch cannot overwrite a change made on the phone.
///
/// The window covers every day with a transfer still waiting to go, so each report is a
/// superset of the ones it replaces and the queue never holds more than one. Records the phone
/// already has come back to it too. That is harmless, because completions merge on
/// `recordedAt` and runs merge by `RoutineRun.merged(with:)`, and it is what makes a write the
/// watch recorded but never managed to send turn up in the next report anyway.
public struct WatchReport: Codable, Sendable {
    public static let currentFormat = 1

    public let format: Int
    /// The first day this report covers. Every record on or after it is included.
    public let earliestDay: DayKey
    public let completions: [CompletionEvent]
    public let runs: [RoutineRun]

    public init(earliestDay: DayKey, completions: [CompletionEvent], runs: [RoutineRun]) {
        self.format = Self.currentFormat
        self.earliestDay = earliestDay
        self.completions = completions
        self.runs = runs
    }
}

/// Turns bridge payloads into bytes and back.
///
/// Both devices always ship together inside one iOS app, but they install and update at
/// different moments, so for a while one can be newer than the other. A payload in a format
/// this build does not know is refused rather than half-read.
public enum BridgeCodec {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// Written by a newer build. Update this device.
        case unsupportedFormat(Int)

        public var description: String {
            switch self {
            case .unsupportedFormat(let format):
                return "Sent by a newer version of Habit Planner (format \(format)). Update this device."
            }
        }
    }

    /// Sorted keys, so the same records encode to the same bytes and an unchanged snapshot
    /// can be recognised and not sent again.
    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decodeSnapshot(_ data: Data) throws -> WatchSnapshot {
        try checkFormat(of: data, supported: WatchSnapshot.currentFormat)
        return try JSONDecoder().decode(WatchSnapshot.self, from: data)
    }

    public static func decodeReport(_ data: Data) throws -> WatchReport {
        try checkFormat(of: data, supported: WatchReport.currentFormat)
        return try JSONDecoder().decode(WatchReport.self, from: data)
    }

    /// Reads the format number alone first, so a newer payload whose shape this build cannot
    /// decode is reported as newer, not as corrupt.
    private static func checkFormat(of data: Data, supported: Int) throws {
        struct Header: Decodable { let format: Int }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.format <= supported else { throw Failure.unsupportedFormat(header.format) }
    }
}

extension RoutineRun {
    /// Two copies of the same run combined, keeping what either one knows.
    ///
    /// The watch and the phone both hold copies of today's runs, and a copy can arrive late or
    /// more than once. A merge that let the newer arrival win would be wrong in exactly those
    /// cases: a stale copy with a step not yet ended would reopen a step the other device had
    /// closed. So a known clock is never replaced by an unknown one.
    ///
    /// Where both copies know a value, the rule picks one the same way whichever side it runs
    /// on: the earliest start, the latest end, the lowest position. That makes the merge
    /// commutative, associative and idempotent, so any number of copies arriving in any order
    /// settle on one answer. The lessons from the completion fold apply unchanged: a merge whose
    /// result is stored and merged again has to give the same answer incrementally as in one go.
    ///
    /// The cost is that an undo is not carried across. A step reopened on one device stays
    /// closed in the other's copy of the run. The retraction the undo wrote still travels, so
    /// the habit reads as not done everywhere and can be ticked from the list. Nothing scores
    /// the run itself.
    public func merged(with other: RoutineRun) -> RoutineRun {
        precondition(id == other.id, "Merging \(other.id) into \(id)")

        var byHabit: [UUID: RoutineStep] = [:]
        for step in steps + other.steps {
            guard let kept = byHabit[step.habitID] else {
                byHabit[step.habitID] = step
                continue
            }
            byHabit[step.habitID] = RoutineStep(
                habitID: step.habitID,
                position: Swift.min(kept.position, step.position),
                startedAt: earliest(kept.startedAt, step.startedAt),
                endedAt: latest(kept.endedAt, step.endedAt)
            )
        }

        // The time zone of whichever copy started first, with the identifier breaking a tie,
        // so the choice is a minimum over a total order and does not depend on which side runs.
        let zoneSource = [self, other].min { lhs, rhs in
            let left = lhs.startedAt ?? .distantFuture
            let right = rhs.startedAt ?? .distantFuture
            if left != right { return left < right }
            return lhs.timeZoneIdentifier < rhs.timeZoneIdentifier
        } ?? self

        return RoutineRun(
            routine: routine,
            dayKey: dayKey,
            startedAt: earliest(startedAt, other.startedAt),
            endedAt: latest(endedAt, other.endedAt),
            timeZoneIdentifier: zoneSource.timeZoneIdentifier,
            steps: byHabit.values.sorted {
                $0.position == $1.position
                    ? $0.habitID.uuidString < $1.habitID.uuidString
                    : $0.position < $1.position
            }
        )
    }
}

private func earliest(_ lhs: Date?, _ rhs: Date?) -> Date? {
    guard let lhs else { return rhs }
    guard let rhs else { return lhs }
    return Swift.min(lhs, rhs)
}

private func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
    guard let lhs else { return rhs }
    guard let rhs else { return lhs }
    return Swift.max(lhs, rhs)
}
