#if DEBUG
import AppKit
import HabitKit
import SwiftUI

/// Walks the app through its pages and saves a picture of each, for checking the Mac UI
/// without a person at the machine.
///
/// Debug only, reached with `-SnapshotPages` alongside the in-memory demo arguments. The app
/// draws its own windows into an image, which needs none of the Screen Recording or automation
/// permissions an outside tool would. Pictures land in the app's temporary directory, which for
/// the sandboxed app is inside its container, and the app quits when it is done.
@Observable
final class SnapshotDriver {
    static let shared = SnapshotDriver()
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-SnapshotPages") }

    var page: MacRootView.Page?
    var path: [UUID] = []
    var running: RoutineSlot?

    func run(model: AppModel) async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Snapshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(2))
        await model.reload()

        page = .routine(.morning)
        await snap("1-routine", in: directory)
        // The sidebar draws its text with vibrancy, which a view cannot capture of itself, so
        // its rows are read from the view tree instead.
        if let window = NSApp.windows.first(where: \.canBecomeMain), let root = window.contentView {
            let tables = Self.tables(in: root)
            let summary = tables.map { "\(type(of: $0)) at x=\(Int($0.convert($0.bounds, to: nil).minX)): \($0.numberOfRows) rows" }
            try? summary.joined(separator: "\n").write(to: directory.appending(path: "1-sidebar.txt"),
                                                      atomically: true, encoding: .utf8)
        }

        running = .morning
        await snap("2-runner", in: directory)
        running = nil
        try? await Task.sleep(for: .seconds(1))

        page = .lockIn
        await snap("3-lock-in", in: directory)
        page = .rates
        await snap("4-rates", in: directory)

        if let stretch = model.histories.first(where: { $0.habit.title == "Stretch" }) {
            path = [stretch.habit.id]
            await snap("5-habit-report", in: directory)
        }
        print("Snapshots written to \(directory.path())")
        NSApp.terminate(nil)
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView { return [table] }
        return view.subviews.flatMap(tables(in:))
    }

    private func snap(_ name: String, in directory: URL) async {
        try? await Task.sleep(for: .seconds(1.5))
        // The sheet if one is up, since that is what the step is about, otherwise the window.
        let windows = NSApp.windows.filter(\.isVisible)
        guard let window = windows.first(where: \.isSheet) ?? windows.first(where: { $0.isMainWindow || $0.canBecomeMain }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
    }
}
#endif
