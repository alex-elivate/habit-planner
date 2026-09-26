import CoreData
import OSLog
import UIKit

/// Keeps the app running after a write made in the background until iCloud has uploaded it.
///
/// The widget's Done button, Siri and a report from the watch all write while the app is in the
/// background, and iOS suspends it a moment later. Found on a device: the tick then stayed on
/// the phone until the app was next opened, so the Mac showed it undone. Holding background
/// time until an upload that started after the latest write has finished gives iCloud the
/// chance to send it. The latest, because one upload started after an earlier write may not
/// carry a later one.
///
/// `begin()` before a write, so the app stays up while it happens, and `wrote()` once it has
/// saved, which is the moment an upload has to start after. Capped, because iOS allows about
/// half a minute and ends the app if it overstays.
///
/// Nothing is held while the app is on screen, where it keeps running anyway.
@MainActor
final class CloudUploadHold {
    static let shared = CloudUploadHold()

    private var task: UIBackgroundTaskIdentifier = .invalid
    private var observer: (any NSObjectProtocol)?
    private var deadline: Task<Void, Never>?
    /// When the latest write saved. Only an upload that started after it can carry it.
    private var since: Date?

    private static let limit: Duration = .seconds(25)
    private static let log = Logger(subsystem: "org.trusler.habitplanner", category: "upload")

    /// Call just before a background write. Several writes in a row share one hold.
    func begin() {
        guard UIApplication.shared.applicationState != .active else { return }
        if task == .invalid {
            task = UIApplication.shared.beginBackgroundTask(withName: "iCloud upload") { [weak self] in
                MainActor.assumeIsolated { self?.end(reason: "time ran out") }
            }
        }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                        as? NSPersistentCloudKitContainer.Event,
                      event.type == .export, event.endDate != nil, event.succeeded else { return }
                let started = event.startDate
                MainActor.assumeIsolated { self?.exportFinished(startedAt: started) }
            }
        }
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.limit)
            guard !Task.isCancelled else { return }
            self?.end(reason: "no upload seen")
        }
    }

    /// Call once a write has saved. Does nothing outside a hold.
    func wrote() {
        guard task != .invalid else { return }
        since = .now
    }

    private func exportFinished(startedAt started: Date) {
        guard let since, started >= since else { return }
        end(reason: "uploaded")
    }

    private func end(reason: String) {
        guard task != .invalid else { return }
        Self.log.info("Background hold ended: \(reason, privacy: .public)")
        deadline?.cancel()
        deadline = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        since = nil
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
