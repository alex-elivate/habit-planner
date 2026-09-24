import Foundation
import Testing
@testable import HabitKit

private func t(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

private func sampleSnapshot() -> WatchSnapshot {
    let habitID = UUID()
    let habit = Habit(
        id: habitID, title: "Stretch", cue: "after I brush my teeth", twoMinuteVersion: "one stretch",
        identityStatement: "I look after my body", routine: .evening, order: 3,
        schedule: .daysOfWeek([.monday, .wednesday, .saturday]), completionSource: .automatic,
        startedOn: referenceToday.advanced(by: -40)
    )
    // Fractional seconds on purpose. Conflicts resolve on `recordedAt`, so a clock that came
    // back rounded could flip which of two assertions wins.
    let done = CompletionEvent(habitID: habitID, dayKey: referenceToday.advanced(by: -2),
                               source: .automatic, occurredAt: t(1_000.123_456),
                               recordedAt: t(2_000.654_321), timeZoneIdentifier: "Asia/Kolkata")
    let undone = CompletionEvent(habitID: habitID, dayKey: referenceToday.advanced(by: -1),
                                 status: .retracted, occurredAt: t(3_000.5), recordedAt: t(4_000.25),
                                 timeZoneIdentifier: "America/Denver")
    let pause = LifecycleEvent(habitID: habitID, dayKey: referenceToday.advanced(by: -10),
                               state: .paused, occurredAt: t(500.75), timeZoneIdentifier: "UTC")
    let run = RoutineRun(
        routine: .evening, dayKey: referenceToday, startedAt: t(6_000.1), endedAt: nil,
        timeZoneIdentifier: "Europe/London",
        steps: [RoutineStep(habitID: habitID, position: 0, startedAt: t(6_000.1), endedAt: nil)]
    )
    return WatchSnapshot(generatedAt: t(9_999.9), habits: [habit], completions: [done, undone],
                         lifecycle: [pause], runs: [run])
}

@Suite("Watch payloads")
struct WatchPayloadTests {

    // MARK: Codec

    @Test("A snapshot survives the trip with every field intact")
    func snapshotRoundTrip() throws {
        let original = sampleSnapshot()
        let decoded = try BridgeCodec.decodeSnapshot(try BridgeCodec.encode(original))

        #expect(decoded.format == WatchSnapshot.currentFormat)
        #expect(decoded.generatedAt == original.generatedAt)
        #expect(decoded.habits == original.habits)
        #expect(decoded.runs == original.runs)
        // `CompletionEvent ==` compares only the identifier, which would pass with every clock
        // wrong. Each field is checked on its own.
        for (lhs, rhs) in zip(decoded.completions, original.completions) {
            #expect(lhs.id == rhs.id)
            #expect(lhs.status == rhs.status)
            #expect(lhs.source == rhs.source)
            #expect(lhs.occurredAt == rhs.occurredAt)
            #expect(lhs.recordedAt == rhs.recordedAt)
            #expect(lhs.timeZoneIdentifier == rhs.timeZoneIdentifier)
        }
        #expect(decoded.completions.count == original.completions.count)
        for (lhs, rhs) in zip(decoded.lifecycle, original.lifecycle) {
            #expect(lhs.id == rhs.id)
            #expect(lhs.state == rhs.state)
            #expect(lhs.occurredAt == rhs.occurredAt)
            #expect(lhs.timeZoneIdentifier == rhs.timeZoneIdentifier)
        }
        #expect(decoded.lifecycle.count == original.lifecycle.count)
    }

    @Test("A report survives the trip")
    func reportRoundTrip() throws {
        let snapshot = sampleSnapshot()
        let original = WatchReport(earliestDay: referenceToday.advanced(by: -1),
                                   completions: snapshot.completions, runs: snapshot.runs)
        let decoded = try BridgeCodec.decodeReport(try BridgeCodec.encode(original))

        #expect(decoded.earliestDay == original.earliestDay)
        #expect(decoded.runs == original.runs)
        #expect(decoded.completions.map(\.recordedAt) == original.completions.map(\.recordedAt))
        #expect(decoded.completions.map(\.status) == original.completions.map(\.status))
    }

    @Test("The same records encode to the same bytes every time")
    func encodingIsStable() throws {
        // The phone skips sending a snapshot identical to the last one. A `Set` somewhere in
        // the payload would make every encoding differ and send it on every reload.
        let snapshot = sampleSnapshot()
        let first = try BridgeCodec.encode(snapshot)
        for _ in 0..<50 {
            #expect(try BridgeCodec.encode(snapshot) == first)
        }
    }

    @Test("A payload from a newer build is refused as newer, not read as far as it goes")
    func newerFormatRefused() throws {
        var object = try #require(
            try JSONSerialization.jsonObject(with: BridgeCodec.encode(sampleSnapshot())) as? [String: Any]
        )
        object["format"] = WatchSnapshot.currentFormat + 1
        // A field this build has never heard of, which a newer format might well add.
        object["somethingNew"] = ["x": 1]
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: BridgeCodec.Failure.unsupportedFormat(WatchSnapshot.currentFormat + 1)) {
            try BridgeCodec.decodeSnapshot(data)
        }

        var report = try #require(
            try JSONSerialization.jsonObject(with: BridgeCodec.encode(
                WatchReport(earliestDay: referenceToday, completions: [], runs: [])
            )) as? [String: Any]
        )
        report["format"] = WatchReport.currentFormat + 1
        #expect(throws: BridgeCodec.Failure.unsupportedFormat(WatchReport.currentFormat + 1)) {
            try BridgeCodec.decodeReport(try JSONSerialization.data(withJSONObject: report))
        }
    }

    @Test("Neither payload has anywhere to put a health binding")
    func payloadsCarryOnlyTheExpectedFields() throws {
        // A binding for a medication habit names a drug, and it stays on the device that made
        // it. Pinning the exact top-level keys means adding a field for bindings, or anything
        // else, fails here and has to be argued for.
        let snapshot = try #require(
            try JSONSerialization.jsonObject(with: BridgeCodec.encode(sampleSnapshot())) as? [String: Any]
        )
        #expect(Set(snapshot.keys) == ["format", "generatedAt", "habits", "completions", "lifecycle", "runs"])

        let report = try #require(
            try JSONSerialization.jsonObject(with: BridgeCodec.encode(
                WatchReport(earliestDay: referenceToday, completions: [], runs: [])
            )) as? [String: Any]
        )
        #expect(Set(report.keys) == ["format", "earliestDay", "completions", "runs"])
    }

    // MARK: Run merge

    private static let habitA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private static let habitB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private static let habitC = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

    private func run(
        startedAt: Date?, endedAt: Date?, zone: String = "UTC", steps: [RoutineStep]
    ) -> RoutineRun {
        RoutineRun(routine: .morning, dayKey: referenceToday, startedAt: startedAt, endedAt: endedAt,
                   timeZoneIdentifier: zone, steps: steps)
    }

    /// Copies of one run as different devices might hold it at different moments.
    private var copies: [RoutineRun] {
        [
            run(startedAt: t(100), endedAt: nil, zone: "Europe/London", steps: [
                RoutineStep(habitID: Self.habitA, position: 0, startedAt: t(100), endedAt: t(160)),
                RoutineStep(habitID: Self.habitB, position: 1, startedAt: t(160), endedAt: nil),
            ]),
            run(startedAt: t(90), endedAt: t(400), zone: "America/New_York", steps: [
                RoutineStep(habitID: Self.habitA, position: 0, startedAt: t(90), endedAt: nil),
                RoutineStep(habitID: Self.habitC, position: 1, startedAt: t(200), endedAt: t(400)),
            ]),
            run(startedAt: nil, endedAt: nil, zone: "Asia/Tokyo", steps: [
                RoutineStep(habitID: Self.habitB, position: 2, startedAt: nil, endedAt: t(300)),
            ]),
            run(startedAt: t(100), endedAt: t(350), zone: "Europe/London", steps: []),
        ]
    }

    private func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { index -> [[T]] in
            var rest = items
            let head = rest.remove(at: index)
            return permutations(rest).map { [head] + $0 }
        }
    }

    @Test("Copies of a run merge to one answer in every arrival order")
    func runMergeIsOrderIndependent() {
        // The store merges one copy at a time into the row it already holds, so incremental
        // has to equal all at once. Every ordering of four copies, folded left to right.
        let orders = permutations(copies)
        let answers = orders.map { order in
            order.dropFirst().reduce(order[0]) { $0.merged(with: $1) }
        }
        #expect(orders.count == 24)
        #expect(Set(answers).count == 1)

        // And in a different grouping: (a+b) + (c+d) against the left fold.
        let c = copies
        let grouped = c[0].merged(with: c[1]).merged(with: c[2].merged(with: c[3]))
        #expect(grouped == answers[0])
    }

    @Test("Merging a copy with itself changes nothing")
    func runMergeIsIdempotent() {
        for copy in copies {
            let normalised = copy.merged(with: copy)
            #expect(normalised.merged(with: copy) == normalised)
            #expect(normalised.merged(with: normalised) == normalised)
        }
    }

    @Test("A known clock is never replaced by an unknown one")
    func runMergeKeepsWhatEitherSideKnows() {
        let merged = copies.dropFirst().reduce(copies[0]) { $0.merged(with: $1) }
        let steps = Dictionary(uniqueKeysWithValues: merged.steps.map { ($0.habitID, $0) })

        #expect(merged.startedAt == t(90))
        #expect(merged.endedAt == t(400))
        // The zone of the copy that started first.
        #expect(merged.timeZoneIdentifier == "America/New_York")
        #expect(steps.count == 3)
        #expect(steps[Self.habitA]?.startedAt == t(90))
        #expect(steps[Self.habitA]?.endedAt == t(160))
        #expect(steps[Self.habitB]?.startedAt == t(160))
        #expect(steps[Self.habitB]?.endedAt == t(300))
        #expect(steps[Self.habitB]?.position == 1)
        #expect(steps[Self.habitC]?.endedAt == t(400))
    }

    @Test("A stale copy arriving late does not reopen a step the other device closed")
    func staleCopyDoesNotReopen() {
        let current = run(startedAt: t(100), endedAt: nil, steps: [
            RoutineStep(habitID: Self.habitA, position: 0, startedAt: t(100), endedAt: t(150)),
            RoutineStep(habitID: Self.habitB, position: 1, startedAt: t(150), endedAt: nil),
        ])
        let stale = run(startedAt: t(100), endedAt: nil, steps: [
            RoutineStep(habitID: Self.habitA, position: 0, startedAt: t(100), endedAt: nil),
        ])

        for merged in [current.merged(with: stale), stale.merged(with: current)] {
            #expect(merged.steps.first { $0.habitID == Self.habitA }?.endedAt == t(150))
            #expect(merged.steps.count == 2)
        }
    }
}
