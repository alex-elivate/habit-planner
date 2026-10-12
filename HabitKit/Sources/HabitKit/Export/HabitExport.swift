import Foundation

/// Everything the store holds, as one file the person can keep.
///
/// A copy outside iCloud, so a schema problem or a bad write is not the only record of
/// months of habits. It holds the records themselves rather than anything worked out from
/// them: scores, streaks and states are folds, and a later version can fold the same
/// records again. Nothing reads it back yet. Holding every record is what keeps that open.
///
/// Records the store could not read are listed by description rather than left out
/// silently, so an export that is missing something says so.
///
/// Health links are left out. Each is a setting on one device, never synced, and a
/// medication's identifier is an archived HealthKit object that means nothing elsewhere.
public struct HabitExport: Codable, Sendable {
    /// Raised when a field changes meaning, so a reader can tell which layout it has.
    public static let currentFormat = 1

    public let format: Int
    public let exportedAt: Date
    public let habits: [Habit]
    public let completions: [CompletionEvent]
    public let lifecycle: [LifecycleEvent]
    public let routineRuns: [RoutineRun]
    public let plannedHabits: [PlannedHabit]
    public let unreadableRecords: [String]

    /// Sorted by day and habit, so two exports can be compared line by line.
    public init(
        exportedAt: Date,
        habits: [Habit],
        completions: [CompletionEvent],
        lifecycle: [LifecycleEvent],
        routineRuns: [RoutineRun],
        plannedHabits: [PlannedHabit],
        unreadableRecords: [String]
    ) {
        format = Self.currentFormat
        self.exportedAt = exportedAt
        self.habits = habits
        self.completions = completions.sorted {
            ($0.dayKey, $0.habitID.uuidString, $0.slotIndex) < ($1.dayKey, $1.habitID.uuidString, $1.slotIndex)
        }
        self.lifecycle = lifecycle.sorted {
            ($0.dayKey, $0.habitID.uuidString, $0.occurredAt) < ($1.dayKey, $1.habitID.uuidString, $1.occurredAt)
        }
        self.routineRuns = routineRuns.sorted {
            ($0.dayKey, $0.routine.rawValue) < ($1.dayKey, $1.routine.rawValue)
        }
        self.plannedHabits = plannedHabits.sorted { $0.routine.rawValue < $1.routine.rawValue }
        self.unreadableRecords = unreadableRecords.sorted()
    }

    /// The whole export, readable by eye: indented, keys in order, dates in ISO 8601.
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> HabitExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HabitExport.self, from: data)
    }

    /// One row per day a habit was marked, for a spreadsheet.
    ///
    /// Only completions, since that is the question a spreadsheet gets asked. Skips and the
    /// rest are in the JSON. A day marked done and then taken back reads "Not done", and its
    /// time is left empty, because a retraction carries no time of doing.
    public func completionsCSV() -> String {
        let titles = Dictionary(habits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var lines = ["Date,Routine,Habit,Result,Recorded by,Done at,Time zone"]
        for event in completions {
            let habit = titles[event.habitID]
            let done = event.status == .completed
            let doneAt = done ? Self.localTime(event.occurredAt, in: event.timeZoneIdentifier) : ""
            let fields = [
                event.dayKey.description,
                habit?.routine.rawValue.capitalized ?? "",
                habit?.title ?? event.habitID.uuidString,
                done ? "Done" : "Not done",
                event.source == .manual ? "You" : "Health",
                doneAt,
                event.timeZoneIdentifier,
            ]
            lines.append(fields.map(Self.csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Quoted when it holds a comma, quote or line break, with quotes doubled, as RFC 4180
    /// has it. A habit title is free text. One starting with `=`, `+`, `-` or `@` gets a
    /// leading apostrophe, so a spreadsheet shows it rather than running it as a formula.
    static func csvField(_ raw: String) -> String {
        let value = raw.first.map { "=+-@".contains($0) } == true ? "'" + raw : raw
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// The wall-clock time where it was done, which is what the person remembers.
    static func localTime(_ date: Date, in identifier: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier) ?? .gmt
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
