import Foundation
import HabitKit
import HabitStore
import OSLog
import SwiftData
import WidgetKit

/// One moment of a widget's timeline.
struct GlanceEntry: TimelineEntry {
    enum Content {
        case glance(Glance)
        /// The app has not created its store yet.
        case noStore
        /// The store exists and could not be read. Never shown as "not set up", which would
        /// tell somebody with months of history that they have none.
        case unreadable
    }

    let date: Date
    let content: Content
    let timeZone: TimeZone

    /// The routine this entry puts first. Worked out per entry, because it changes at noon.
    var featured: RoutineSlot {
        guard case .glance(let glance) = content else { return .morning }
        return glance.featured(at: date, in: timeZone)
    }
}

/// Serves every widget in the extension. iPhone and watch alike.
///
/// Nothing is cached between requests and nothing is written. Each timeline opens the store read
/// only, folds it with the same HabitKit code the app uses, and lets the container go. The app
/// asks for a new timeline whenever something a widget shows has changed, so the only reloads
/// the timeline has to plan for itself are the ones the clock causes.
struct GlanceProvider: TimelineProvider {

    func placeholder(in context: Context) -> GlanceEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        // The gallery preview. The person's own habits there would be a surprise, so it gets
        // the sample, and so does a widget whose app has never been opened.
        guard !context.isPreview else { return completion(.sample) }
        let completion = Completion(completion)
        Task {
            let entry = await GlanceTimeline.entries(from: .now, nowOnly: true).first
            completion(entry ?? .sample)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        let completion = Completion(completion)
        Task {
            // `.atEnd` asks again after the last entry, which is the next midnight.
            completion(Timeline(entries: await GlanceTimeline.entries(from: .now), policy: .atEnd))
        }
    }
}

/// A WidgetKit completion handler, carried into the task that calls it.
///
/// WidgetKit accepts the call from any thread, and each handler is called exactly once, but the
/// SDK does not mark the closures `Sendable`, so Swift 6 refuses to let a `Task` capture them.
/// This says so in one place rather than at every call.
private struct Completion<Value>: @unchecked Sendable {
    let call: (Value) -> Void
    init(_ call: @escaping (Value) -> Void) { self.call = call }
    func callAsFunction(_ value: Value) { call(value) }
}

enum GlanceTimeline {

    /// Entries from `now` until the next midnight.
    ///
    /// Only the moments where the answer can change without any record changing: noon, when
    /// the featured routine moves to the evening, and midnight, when today becomes tomorrow and
    /// every habit is due again. Each day gets its own fold, since a fold is made for one day.
    ///
    /// `nowOnly` is for a snapshot, which shows one entry and has no use for tomorrow's fold.
    static func entries(from now: Date, timeZone: TimeZone = .current, nowOnly: Bool = false) async -> [GlanceEntry] {
        let store: HabitStoreActor
        switch openStore() {
        case .success(let opened):
            store = opened
        case .failure(.missing):
            return [GlanceEntry(date: now, content: .noStore, timeZone: timeZone)]
        case .failure(.unreadable):
            return [GlanceEntry(date: now, content: .unreadable, timeZone: timeZone)]
        }
        do {
            let dates = nowOnly ? [now] : moments(from: now, in: timeZone)
            let glances = try await store.glances(at: dates, in: timeZone)
            return zip(dates, glances).map { GlanceEntry(date: $0, content: .glance($1), timeZone: timeZone) }
        } catch {
            log.error("Could not read the store: \(String(describing: error), privacy: .public)")
            return [GlanceEntry(date: now, content: .unreadable, timeZone: timeZone)]
        }
    }

    /// Now, then noon today if it is still ahead, then the start of tomorrow.
    static func moments(from now: Date, in timeZone: TimeZone) -> [Date] {
        let today = DayKey(now, in: timeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var result = [now]
        if let noon = calendar.date(bySettingHour: Glance.eveningBeginsAtHour, minute: 0, second: 0,
                                    of: today.start(in: timeZone)),
           noon > now {
            result.append(noon)
        }
        result.append(today.advanced(by: 1).start(in: timeZone))
        return result
    }

    private static let log = Logger(subsystem: "org.trusler.habitplanner", category: "widget")

    enum OpenFailure: Error {
        /// No store file yet. The app has never been opened on this device.
        case missing
        /// A store file is there and did not open.
        case unreadable
    }

    /// The app's store, read only.
    ///
    /// Opened from the App Group, which on the watch is the watch's own container. The widget
    /// never opens the health store: it is outside the group on purpose, and a widget has no
    /// use for what is in it.
    ///
    /// A read-only open fails both when the file is missing and when it is there and cannot be
    /// read, for instance after an update the app has not yet migrated. Those need different
    /// words on screen, so the file is looked for rather than guessed from the error.
    private static func openStore() -> Result<HabitStoreActor, OpenFailure> {
        do {
            let container = try HabitStoreContainer.container(role: .readOnlyWidget, identifiers: AppIdentifiers.store)
            return .success(HabitStoreActor(modelContainer: container))
        } catch {
            guard storeFileExists else { return .failure(.missing) }
            log.error("Could not open the store: \(String(describing: error), privacy: .public)")
            return .failure(.unreadable)
        }
    }

    /// Where SwiftData puts the synced store inside the group: `Library/Application Support`,
    /// named after the configuration.
    private static var storeFileExists: Bool {
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup
        ) else { return false }
        let file = group.appending(path: "Library/Application Support/\(HabitStoreContainer.syncedStoreName).store")
        return FileManager.default.fileExists(atPath: file.path())
    }
}

extension GlanceEntry {
    /// What the gallery and a placeholder show. Never the person's own habits.
    static var sample: GlanceEntry {
        let zone = TimeZone.current
        let now = Date.now
        let glance = Glance(day: DayKey(now, in: zone), routines: [
            RoutineGlance(routine: .morning, progress: Progress(completed: 1, total: 3),
                          nextHabitTitle: "Stretch", remaining: 2, unlock: .open, planned: "Meditate"),
            RoutineGlance(routine: .evening, progress: Progress(completed: 0, total: 1),
                          nextHabitTitle: "Read ten pages", remaining: 1, unlock: .open, planned: nil),
        ])
        return GlanceEntry(date: now, content: .glance(glance), timeZone: zone)
    }
}
