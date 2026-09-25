import Foundation
import HabitKit
import HabitStore
import Observation
import OSLog
import WatchConnectivity

/// The watch's end of the bridge to the iPhone.
///
/// The watch keeps its own store and never talks to CloudKit. See `HabitStoreContainer`
/// for the Apple bug that rules it out. Everything reaches iCloud through the phone:
///
/// - **From the phone**, a `WatchSnapshot` file with every record. Merged, never swapped in,
///   so a tick made here while the phone was away survives a snapshot built before the phone
///   heard about it.
/// - **To the phone**, a `WatchReport` file with every completion and run from a window of
///   recent days. Queued by the system, so it waits out the phone being in another room.
///
/// Reports go as files rather than user info for the same reason snapshots do. User info has
/// an undocumented size limit, and a watch left unpaired for a week would build a report that
/// hits it and fails outright.
///
/// ### Nothing written here is lost on the way
///
/// The store is written first and the report built from it afterwards, so the report always
/// includes the write. The window covers every day with a report still waiting, and each new
/// report replaces those, so the queue stays at one file.
///
/// The window also reaches back to the earliest write the phone has not confirmed receiving.
/// Without that, a write followed by the app being killed before the report was queued would
/// only be sent if the watch app opened again the same day or the next.
@Observable
final class WatchBridge: NSObject {
    nonisolated private static let log = Logger(subsystem: "org.trusler.habitplanner", category: "bridge")

    /// When the last snapshot from the phone was merged. Shown so a stale watch is visible.
    private(set) var lastSnapshotAt: Date?
    private(set) var problem: String?

    @ObservationIgnored private let model: WatchModel
    @ObservationIgnored private let session: WCSession?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pendingReport: Task<Void, Never>?
    @ObservationIgnored private var sending: Task<Void, Never>?
    @ObservationIgnored private var merging: Task<Void, Never>?

    private static let lastSnapshotKey = "bridge.lastSnapshotAt"
    private static let unconfirmedKey = "bridge.unconfirmedSince"

    init(model: WatchModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        self.session = WCSession.isSupported() ? WCSession.default : nil
        self.lastSnapshotAt = defaults.object(forKey: Self.lastSnapshotKey) as? Date
        super.init()
    }

    func start() {
        guard let session else { return }
        session.delegate = self
        session.activate()
        model.beforeWrite = { [weak self] day in self?.noteUnconfirmed(day) }
        model.afterWrite = { [weak self] in self?.scheduleReport() }
    }

    // MARK: - To the phone

    /// The earliest day holding a write the phone has not confirmed.
    private var unconfirmedSince: DayKey? {
        (defaults.object(forKey: Self.unconfirmedKey) as? Int).flatMap(DayKey.init(validating:))
    }

    /// Recorded before the write, so a write that lands and then loses its report still
    /// widens the next report's window.
    private func noteUnconfirmed(_ day: DayKey) {
        if let current = unconfirmedSince, current <= day { return }
        defaults.set(day.rawValue, forKey: Self.unconfirmedKey)
    }

    func scheduleReport() {
        pendingReport?.cancel()
        pendingReport = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let previous = sending
            let pass = Task {
                await previous?.value
                await sendReport()
            }
            sending = pass
            await pass.value
        }
    }

    private func sendReport() async {
        guard let session, session.activationState == .activated, session.isCompanionAppInstalled else {
            Self.log.info("Report not sent: session \(String(describing: self.session?.activationState.rawValue), privacy: .public), companion installed \(self.session?.isCompanionAppInstalled ?? false)")
            return
        }
        let waiting = session.outstandingFileTransfers.filter { Self.isReport($0) }
        let today = DayKey(.now, in: model.timeZone)
        // Yesterday always, because an evening run past midnight writes to the day it began.
        let earliest = ([today.advanced(by: -1), unconfirmedSince].compactMap { $0 }
            + waiting.compactMap(Self.earliestDay)).min() ?? today

        do {
            let report = try await model.store.watchReport(from: earliest)
            let outgoing = try Self.directory("OutgoingReports")
            let url = outgoing.appending(path: "report-\(UUID().uuidString).json")
            try BridgeCodec.encode(report).write(to: url, options: .atomic)

            // Queued before the ones it replaces are cancelled, so there is never a moment
            // with nothing on the way.
            session.transferFile(url, metadata: [BridgeKey.kind: BridgeKey.report,
                                                 BridgeKey.earliestDay: earliest.rawValue])
            for transfer in waiting { transfer.cancel() }
            Self.log.info("Report sent from \(earliest.rawValue): \(report.completions.count) completions, replacing \(waiting.count)")
        } catch {
            Self.log.error("Report failed: \(error.localizedDescription, privacy: .public)")
            problem = "Could not prepare your progress for iPhone. \(error.localizedDescription)"
        }
    }

    nonisolated private static func isReport(_ transfer: WCSessionFileTransfer) -> Bool {
        transfer.file.metadata?[BridgeKey.kind] as? String == BridgeKey.report
    }

    nonisolated private static func earliestDay(_ transfer: WCSessionFileTransfer) -> DayKey? {
        (transfer.file.metadata?[BridgeKey.earliestDay] as? Int).flatMap(DayKey.init(validating:))
    }

    /// A report reached the phone. If it covered the earliest unconfirmed write and nothing
    /// else is waiting, the phone has everything.
    private func confirmDelivery(of delivered: URL, from earliest: DayKey?) {
        guard let session, let earliest else { return }
        // The finished transfer may still be listed as outstanding while this runs. Counting
        // it would leave the marker set for good, and every later report would reach back to
        // that day.
        let stillWaiting = session.outstandingFileTransfers.contains {
            Self.isReport($0) && $0.file.fileURL != delivered
        }
        if !stillWaiting, let since = unconfirmedSince, earliest <= since {
            defaults.removeObject(forKey: Self.unconfirmedKey)
        }
    }

    // MARK: - From the phone

    private func merge(_ data: Data) {
        let previous = merging
        merging = Task {
            await previous?.value
            do {
                let snapshot = try BridgeCodec.decodeSnapshot(data)
                let result = try await model.store.merge(snapshot)
                Self.log.info("Snapshot merged: \(snapshot.habits.count) habits, \(result.written) rows written")
                lastSnapshotAt = snapshot.generatedAt
                defaults.set(snapshot.generatedAt, forKey: Self.lastSnapshotKey)
                problem = nil
                await model.reload()
            } catch let failure as BridgeCodec.Failure {
                // Nothing to keep: the next snapshot after this watch updates carries it all.
                problem = "Your iPhone has a newer version of Habit Planner. \(failure.description)"
            } catch {
                problem = "Could not read what your iPhone sent. \(error.localizedDescription)"
            }
        }
    }

    nonisolated private static func directory(_ name: String) throws -> URL {
        let url = URL.applicationSupportDirectory.appending(path: "WatchBridge/\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Self.log.info("Session activation: \(activationState.rawValue) \(error?.localizedDescription ?? "", privacy: .public)")
        guard activationState == .activated else { return }
        // Catches up on anything written while the session was down, or before a crash.
        Task { @MainActor in scheduleReport() }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        Self.log.info("Snapshot received")
        // The system deletes the file when this returns, so it is read here, synchronously.
        guard let data = try? Data(contentsOf: file.fileURL) else {
            Task { @MainActor in problem = "A snapshot from your iPhone could not be opened." }
            return
        }
        Task { @MainActor in merge(data) }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let url = fileTransfer.file.fileURL
        try? FileManager.default.removeItem(at: url)
        guard error == nil, Self.isReport(fileTransfer) else { return }
        let earliest = Self.earliestDay(fileTransfer)
        Task { @MainActor in confirmDelivery(of: url, from: earliest) }
    }
}
