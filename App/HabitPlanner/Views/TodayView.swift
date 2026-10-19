import HabitKit
import SwiftUI
import UIKit

struct TodayView: View {
    @Environment(AppModel.self) private var model
    /// A routine a reminder, the widget or Siri asked for. Scrolled to, then cleared.
    @Binding var focus: RoutineSlot?

    @State private var adding: RoutineSlot?
    @State private var showingSettings = false
    @State private var firstLaunch = false

    var body: some View {
        ScrollViewReader { proxy in
            list
                .undoBar()
                // Held until the first load, so a cold launch from a widget scrolls to rows
                // that exist rather than to where they will be.
                .onChange(of: focus, initial: true) { scroll(proxy) }
                .onChange(of: model.hasLoaded) { scroll(proxy) }
        }
    }

    /// Scrolls to the routine asked for, with any sheet over Today closed first.
    private func scroll(_ proxy: ScrollViewProxy) {
        guard let routine = focus, model.hasLoaded else { return }
        focus = nil
        // A habit's page or a sheet still on its way off takes the scroll with it, so wait
        // for it to go. Found once the triggers pushed the evening routine below the fold.
        let covered = !model.coveringPages.isEmpty || adding != nil || showingSettings
        adding = nil
        showingSettings = false
        // A row, not the section. A list scrolls to rows reliably and to sections not at all.
        // The trigger is the routine's top row whenever it has an active habit.
        let habits = model.habits(in: routine)
        let target: AnyHashable = RoutineTriggerRow.firstHabit(of: habits) != nil
            ? AnyHashable(RoutineTriggerRow.scrollID(routine))
            : habits.first.map { AnyHashable($0.habit.id) } ?? AnyHashable(AddHabitRow.scrollID(routine))
        Task {
            // A link arrives while the app is still coming forward, and a list scrolled before
            // it is on screen stays where it was. So wait for the app to be active and for a
            // habit's page to have gone, up to three seconds, then a moment for the last
            // animation. Not for a sheet a row opened: a link does not close it, and waiting
            // on it would only delay the scroll.
            let inactive = UIApplication.shared.applicationState != .active
            for _ in 0..<30 where UIApplication.shared.applicationState != .active
                || !model.coveringPages.isEmpty {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if covered || inactive { try? await Task.sleep(for: .milliseconds(350)) }
            withAnimation { proxy.scrollTo(target, anchor: .top) }
        }
    }

    private var list: some View {
        List {
            Section {
                TodaySummary(progress: ScoreEngine.todayProgress(for: model.histories),
                             score: ScoreEngine.score(for: model.histories))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            ForEach(RoutineSlot.allCases) { routine in
                RoutineSection(routine: routine, add: { adding = routine })
            }

            if !model.archived.isEmpty {
                Section("Archived") {
                    ForEach(model.archived, id: \.habit.id) { history in
                        NavigationLink(value: history.habit.id) {
                            Text(history.habit.title).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Today")
        .navigationDestination(for: UUID.self) { HabitDetailView(habitID: $0).coversUndoBar(isPage: true) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
            }
        }
        .sheet(item: $adding) { routine in
            NavigationStack { HabitEditorView(mode: .new(routine)) }
                .coversUndoBar()
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
                .coversUndoBar()
        }
        // First launch: walk through both routines. Only when nothing at all is stored, so
        // somebody who skipped it sees it again rather than an empty screen, and it never
        // appears over habits.
        .sheet(isPresented: $firstLaunch) {
            NavigationStack { RoutineSetupView(routine: .morning, then: .evening) }
                .coversUndoBar()
        }
        .onChange(of: model.isEmpty, initial: true) { _, empty in
            if empty { firstLaunch = true }
        }
        .refreshable { await model.reload() }
    }
}

struct TodaySummary: View {
    let progress: HabitKit.Progress
    let score: Int?

    var body: some View {
        HStack(spacing: 20) {
            ProgressRing(fraction: progress.fraction, lineWidth: 10)
                .frame(width: 72, height: 72)
                .overlay {
                    Text(progress.total == 0 ? "–" : "\(progress.completed)/\(progress.total)")
                        .font(.headline.monospacedDigit())
                }
                .accessibilityElement()
                .accessibilityLabel(progress.total == 0
                    ? "Nothing due today"
                    : "\(progress.completed) of \(progress.total) done today")

            VStack(alignment: .leading, spacing: 4) {
                Text("Last 7 days").font(.subheadline).foregroundStyle(.secondary)
                Text(score.map { "\($0)" } ?? "–")
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold).monospacedDigit())
                    .accessibilityLabel(score.map { "Score \($0) out of 100" } ?? "No score yet")
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}
