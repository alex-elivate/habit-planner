import HabitKit
import SwiftUI

struct WatchRootView: View {
    @Environment(WatchModel.self) private var model
    @Environment(WatchBridge.self) private var bridge: WatchBridge?
    @Environment(WatchRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    @State private var running: RoutineSlot?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                if model.hasHabits {
                    ForEach(RoutineSlot.allCases) { routine in
                        RoutineRow(routine: routine,
                                   due: model.dueCount(in: routine),
                                   remaining: model.remaining(in: routine),
                                   start: { running = routine })
                    }
                } else {
                    Text("Add habits in Habit Planner on your iPhone. They appear here once it sends them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }

                SyncStatus(lastSnapshotAt: bridge?.lastSnapshotAt, problem: bridge?.problem)
                    .listRowBackground(Color.clear)
            }
            .navigationTitle("Habits")
        }
        .fullScreenCover(item: $running, onDismiss: reload) { routine in
            WatchRunnerView(routine: routine)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.failure ?? "")
        }
        .task { await model.reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
        // Initial as well, because a reminder tapped on a cold launch sets this before the
        // view first observes it.
        .onChange(of: router.requestedRoutine, initial: true) { _, routine in
            guard let routine else { return }
            router.requestedRoutine = nil
            running = routine
        }
    }

    private func reload() {
        Task { await model.reload() }
    }
}

private struct RoutineRow: View {
    let routine: RoutineSlot
    let due: Int
    let remaining: Int
    let start: () -> Void

    var body: some View {
        Button(action: start) {
            HStack {
                Image(systemName: routine.symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.title).font(.headline)
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if due > 0, remaining == 0 {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
        }
        .disabled(remaining == 0)
        .accessibilityLabel(remaining == 0 ? "\(routine.title), \(status)" : "Start \(routine.title.lowercased()) routine")
    }

    private var status: String {
        if due == 0 { return "Nothing due today" }
        if remaining == 0 { return "Done" }
        return remaining == due ? "\(due) to do" : "\(remaining) of \(due) left"
    }
}

/// When the phone last sent the watch its records. A watch that has not heard from its phone
/// in days is still usable, and saying so is better than looking current.
private struct SyncStatus: View {
    let lastSnapshotAt: Date?
    let problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            if let lastSnapshotAt {
                Text("From iPhone \(lastSnapshotAt, format: .relative(presentation: .named))")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
    }
}
