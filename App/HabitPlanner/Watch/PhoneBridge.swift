import Foundation
import HabitKit
import HabitStore
import Observation
import OSLog
import WatchConnectivity

/// The iPhone's end of the watch bridge.
///
/// The watch never talks to CloudKit, so this is the only way its routines reach anywhere
/// else. Two directions, two different WatchConnectivity calls:
///
/// - **To the watch**, a full `WatchSnapshot` by `transferFile`. A snapshot carries every
///   completion ever made, which outgrows the undocumented size limits on application context
///   and user info within a year of daily use. A file has no such limit. Any transfer still
///   waiting is cancelled first, since the new snapshot contains everything the old one did.
/// - **From the watch**, a `WatchReport`, also a file and for the same reason. It queues on the
///   watch and survives the phone being out of range.
///
/// A report is moved into an inbox on disk before anything else happens to it. The system
/// hands it over once, and if the store is busy or the report comes from a newer watch app,
/// dropping it would lose ticks the person made on their wrist. It is deleted only once merged.
@Observable
final class PhoneBridge: NSObject {
    nonisolated private static let log = Logger(subsystem: "org.trusler.habitplanner", category: "bridge")

    /// Why the last report could not be merged, for Settings to show.
    private(set) var problem: String?

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let session: WCSession?
    @ObservationIgnored private var lastSent: Data?
    @ObservationIgnored private var pendingSnapshot: Task<Void, Never>?
    @ObservationIgnored private var merging: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        self.session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
    }

    /// Activates the session. Called at launch, because a report can wake the app in the
    /// background and the delegate has to be in place before the system delivers it.
    func start() {
        guard let session else { return }
        session.delegate = self
        session.activate()
        model.afterReload = { [weak self] in self?.scheduleSnapshot() }
    }

    // MARK: - To the watch

    /// Sends a snapshot shortly, coalescing the burst of reloads a single change causes.
    func scheduleSnapshot() {
        pendingSnapshot?.cancel()
        pendingSnapshot = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await sendSnapshot()
        }
    }

    private func sendSnapshot() async {
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else {
            Self.log.info("Snapshot not sent: session \(String(describing: self.session?.activationState.rawValue), privacy: .public), paired \(self.session?.isPaired ?? false), installed \(self.session?.isWatchAppInstalled ?? false)")
            return
        }
        do {
            let snapshot = try await model.store.watchSnapshot(today: DayKey(.now, in: model.timeZone),
                                                               generatedAt: .now)
            // `generatedAt` differs on every call, so compare the records alone.
            let records = try BridgeCodec.encode(Records(snapshot))
            guard records != lastSent else {
                Self.log.debug("Snapshot unchanged, not sent")
                return
            }

            for transfer in session.outstandingFileTransfers { transfer.cancel() }
            let outgoing = try Self.directory("OutgoingSnapshot")
            // Copies made for transfers now cancelled or long finished.
            for old in (try? FileManager.default.contentsOfDirectory(at: outgoing, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: old)
            }
            let url = outgoing.appending(path: "snapshot-\(UUID().uuidString).json")
            try BridgeCodec.encode(snapshot).write(to: url, options: .atomic)
            session.transferFile(url, metadata: nil)
            lastSent = records
            Self.log.info("Snapshot sent: \(snapshot.habits.count) habits, \(snapshot.completions.count) completions")
        } catch {
            // Nothing lost: the watch keeps what it has, and the next change tries again.
            Self.log.error("Snapshot failed: \(error.localizedDescription, privacy: .public)")
            lastSent = nil
        }
    }

    /// The part of a snapshot that says what the records are, without the moment it was built.
    private struct Records: Encodable {
        let habits: [Habit]
        let completions: [CompletionEvent]
        let lifecycle: [LifecycleEvent]
        let runs: [RoutineRun]

        init(_ snapshot: WatchSnapshot) {
            habits = snapshot.habits
            completions = snapshot.completions
            lifecycle = snapshot.lifecycle
            runs = snapshot.runs
        }
    }

    // MARK: - From the watch

    /// Merges every report waiting on disk, oldest first. Order does not change the result,
    /// but it keeps the log easy to reason about.
    func mergePendingReports() {
        let previous = merging
        merging = Task {
            await previous?.value
            await mergePending()
        }
    }

    private func mergePending() async {
        guard let inbox = try? Self.directory("IncomingReports"),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: inbox, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        else { return }

        var merged = false
        for file in files where file.pathExtension == "json" {
            // Reports arrive with the phone in a pocket and the app in the background. Held
            // open so the ticks reach iCloud, and the Mac, without the app being opened.
            let hold = CloudUploadHold.shared
            hold.begin()
            var saved = false
            defer { hold.finish(saved: saved) }
            do {
                let report = try BridgeCodec.decodeReport(try Data(contentsOf: file))
                let result = try await model.store.merge(report)
                Self.log.info("Report merged: \(report.completions.count) completions, \(result.written) rows written")
                saved = result.written > 0
                try FileManager.default.removeItem(at: file)
                merged = true
                problem = nil
            } catch let failure as BridgeCodec.Failure {
                // Kept. Once this phone updates, the same file merges.
                problem = "Your watch has a newer version of Habit Planner. \(failure.description)"
            } catch is DecodingError {
                // Will never become readable. Moved aside rather than deleted, so the evidence
                // survives, and so it stops blocking the reports behind it.
                if let aside = try? Self.directory("UnreadableReports") {
                    try? FileManager.default.moveItem(at: file, to: aside.appending(path: file.lastPathComponent))
                }
                problem = "A report from your watch could not be read."
            } catch {
                // The store refused the write. Kept for the next launch.
                problem = "Could not save what your watch sent. \(error.localizedDescription)"
            }
        }
        if merged { await model.reload() }
    }

    /// Moves an incoming report into the inbox. Safe from any thread.
    nonisolated private static func keep(_ file: URL) throws {
        let name = "\(Int(Date.now.timeIntervalSince1970 * 1_000))-\(UUID().uuidString).json"
        try FileManager.default.moveItem(at: file, to: try directory("IncomingReports").appending(path: name))
    }

    nonisolated private static func directory(_ name: String) throws -> URL {
        let url = URL.applicationSupportDirectory.appending(path: "WatchBridge/\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension PhoneBridge: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Self.log.info("Session activation: \(activationState.rawValue) \(error?.localizedDescription ?? "", privacy: .public)")
        guard activationState == .activated else { return }
        Task { @MainActor in
            lastSent = nil
            mergePendingReports()
            scheduleSnapshot()
        }
    }

    /// Paired to a different watch, or the watch app was installed. Either way the watch on
    /// the other end may have nothing.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            lastSent = nil
            scheduleSnapshot()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Switching to another watch deactivates the session. Apple's guidance is to activate
    /// again at once so the new watch can connect.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard file.metadata?[BridgeKey.kind] as? String == BridgeKey.report else { return }
        // Moved before this method returns, because the system deletes the file as soon as it
        // does and considers the transfer delivered.
        do {
            try Self.keep(file.fileURL)
        } catch {
            Task { @MainActor in problem = "Could not keep what your watch sent. \(error.localizedDescription)" }
            return
        }
        // iOS may suspend the app as soon as this returns, before the hops to the main actor
        // reach the upload hold. A system activity, which can be started from this thread,
        // keeps it up until the hold has begun.
        let holding = DispatchSemaphore(value: 0)
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Merge a report from the watch") { expired in
            guard !expired else { return }
            _ = holding.wait(timeout: .now() + 10)
        }
        Task { @MainActor in
            // Begun here so the app is held from arrival, and finished once every report has
            // merged. The merge holds each write of its own.
            CloudUploadHold.shared.begin()
            holding.signal()
            mergePendingReports()
            await merging?.value
            CloudUploadHold.shared.finish(saved: false)
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        Self.log.info("Snapshot transfer finished: \(error?.localizedDescription ?? "delivered", privacy: .public)")
        // The file was a copy made for this transfer. A failed one is replaced by the next.
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        if error != nil {
            Task { @MainActor in lastSent = nil }
        }
    }
}
