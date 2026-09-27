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
/// `begin()` before a write returns a token, and `finish(_:saved:)` hands it back once the write
/// is over. The hold ends when no write is still under way and an upload that started after the
/// latest save has finished. A token from a write that was never counted, or from a hold that
/// has since ended, is ignored, so a stray finish cannot release someone else's write.
///
/// Capped, because iOS allows about half a minute and ends the app if it overstays. Nothing is
/// held while the app is on screen, where it keeps running anyway.
@MainActor
final class CloudUploadHold {
    static let shared = CloudUploadHold()

    /// One write's place in one hold.
    struct Token {
        fileprivate let hold: Int
    }

    private var task: UIBackgroundTaskIdentifier = .invalid
    private var observer: (any NSObjectProtocol)?
    private var deadline: Task<Void, Never>?
    /// Counts holds, so a token outlives the hold it came from harmlessly.
    private var generation = 0
    /// Writes begun in this hold and not yet finished.
    private var inFlight = 0
    /// When the latest write in this hold saved. Only an upload that started after it can carry it.
    private var savedAt: Date?
    /// When the latest successful upload in this hold started, in case it finished before the
    /// last write was handed back.
    private var uploadStartedAt: Date?

    private static let limit: Duration = .seconds(25)
    private static let log = Logger(subsystem: "org.trusler.habitplanner", category: "upload")

    /// Call just before a background write. `nil` while the app is on screen.
    func begin() -> Token? {
        guard UIApplication.shared.applicationState != .active else { return nil }
        if task == .invalid {
            generation += 1
            task = UIApplication.shared.beginBackgroundTask(withName: "iCloud upload") { [weak self] in
                MainActor.assumeIsolated { self?.end(reason: "time ran out") }
            }
            observer = NotificationCenter.default.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                        as? NSPersistentCloudKitContainer.Event,
                      event.type == .export, event.endDate != nil, event.succeeded else { return }
                let started = event.startDate
                MainActor.assumeIsolated { self?.uploaded(startedAt: started) }
            }
        }
        inFlight += 1
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.limit)
            guard !Task.isCancelled else { return }
            self?.end(reason: "no upload seen")
        }
        return Token(hold: generation)
    }

    /// Call once the write `token` was given for is over. `saved` is whether it changed
    /// anything, since a write that changed nothing gives iCloud nothing to upload.
    func finish(_ token: Token?, saved: Bool) {
        guard let token, token.hold == generation, task != .invalid, inFlight > 0 else { return }
        inFlight -= 1
        if saved { savedAt = .now }
        endIfDone()
    }

    private func uploaded(startedAt started: Date) {
        uploadStartedAt = max(uploadStartedAt ?? started, started)
        endIfDone()
    }

    private func endIfDone() {
        guard inFlight == 0 else { return }
        guard let savedAt else { return end(reason: "nothing to upload") }
        if let uploadStartedAt, uploadStartedAt >= savedAt { end(reason: "uploaded") }
    }

    private func end(reason: String) {
        guard task != .invalid else { return }
        Self.log.info("Background hold ended: \(reason, privacy: .public)")
        deadline?.cancel()
        deadline = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        inFlight = 0
        savedAt = nil
        uploadStartedAt = nil
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
