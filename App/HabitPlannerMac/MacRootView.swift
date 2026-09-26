import HabitKit
import SwiftUI

/// A sidebar of routines and reports, and a detail column for whichever is chosen.
struct MacRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    enum Page: Hashable {
        case routine(RoutineSlot)
        case lockIn
        case rates
        case archived
    }

    @State private var page: Page? = .routine(.morning)
    @State private var path: [UUID] = []
    @State private var running: RoutineSlot?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $page) {
                Section("Today") {
                    TodaySummary(progress: ScoreEngine.todayProgress(for: model.histories),
                                 score: ScoreEngine.score(for: model.histories))
                        .selectionDisabled()
                    ForEach(RoutineSlot.allCases) { routine in
                        Label(routine.title, systemImage: routine.symbol).tag(Page.routine(routine))
                    }
                }
                Section("Reports") {
                    Label("Lock-in", systemImage: "lock").tag(Page.lockIn)
                    Label("Completion rates", systemImage: "tablecells").tag(Page.rates)
                }
                if !model.archived.isEmpty {
                    Section("Habits") {
                        Label("Archived", systemImage: "archivebox").tag(Page.archived)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            NavigationStack(path: $path) {
                Group {
                    switch page {
                    case .routine(let routine):
                        MacRoutineView(routine: routine, start: { running = $0 })
                    case .lockIn:
                        LockInView()
                    case .rates:
                        RatesView(open: { path.append($0) })
                    case .archived:
                        ArchivedView()
                    case nil:
                        ContentUnavailableView("Choose a routine", systemImage: "sidebar.left")
                    }
                }
                .navigationDestination(for: UUID.self) { HabitReportView(habitID: $0) }
            }
        }
        .sheet(item: $running, onDismiss: { Task { await model.reload() } }) { routine in
            MacRunnerView(routine: routine)
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
            if phase == .active { Task { await model.reload() } }
        }
        // Siri, the Routine menu and a widget all arrive here.
        .onChange(of: router.requestedRoutine, initial: true) { _, routine in
            guard let routine else { return }
            router.requestedRoutine = nil
            running = routine
        }
        .onOpenURL { url in
            guard let routine = WidgetLink.routine(from: url) else { return }
            running = routine
        }
        // A new page starts from its own root, not from a habit opened under another.
        .onChange(of: page) { path = [] }
        #if DEBUG
        .task {
            guard SnapshotDriver.isRequested else { return }
            await SnapshotDriver.shared.run(model: model)
        }
        .onChange(of: SnapshotDriver.shared.page) { _, new in if let new { page = new } }
        .onChange(of: SnapshotDriver.shared.path) { _, new in path = new }
        .onChange(of: SnapshotDriver.shared.running) { _, new in running = new }
        #endif
    }
}

/// Done out of due today, and the seven-day score.
struct TodaySummary: View {
    let progress: HabitKit.Progress
    let score: Int?

    var body: some View {
        HStack(spacing: 12) {
            ProgressRing(fraction: progress.fraction, lineWidth: 5)
                .frame(width: 34, height: 34)
                .overlay {
                    Text(progress.total == 0 ? "–" : "\(progress.completed)/\(progress.total)")
                        .font(.caption2.monospacedDigit())
                }
            VStack(alignment: .leading, spacing: 0) {
                Text("Last 7 days").font(.caption).foregroundStyle(.secondary)
                Text(score.map { "\($0)" } ?? "–").font(.title3.monospacedDigit().weight(.semibold))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// One routine: start it, see its habits in order, reorder them, and add or plan the next.
struct MacRoutineView: View {
    @Environment(AppModel.self) private var model
    let routine: RoutineSlot
    let start: (RoutineSlot) -> Void

    @State private var adding = false

    var body: some View {
        List {
            RoutineSection(routine: routine, start: start, add: { adding = true })
        }
        .navigationTitle(routine.title)
        .toolbar {
            ToolbarItem {
                Button("Start", systemImage: "play.fill") { start(routine) }
                    .disabled(!model.hasWorkRemaining(in: routine))
                    .help("Start the \(routine.title.lowercased()) routine")
            }
            ToolbarItem {
                Button("Add Habit", systemImage: "plus") { adding = true }
                    .disabled(!model.gate(for: routine).isOpen)
                    .keyboardShortcut("n", modifiers: .command)
                    .help(model.gate(for: routine).isOpen ? "Add a habit" : "Locked until the newest habit beds in")
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { HabitEditorView(mode: .new(routine)) }
                .frame(minWidth: 480, minHeight: 540)
        }
        #if DEBUG
        .onChange(of: SnapshotDriver.shared.adding) { _, new in adding = new }
        #endif
    }
}

struct ArchivedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(model.archived, id: \.habit.id) { history in
            NavigationLink(value: history.habit.id) {
                Text(history.habit.title).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Archived")
    }
}
