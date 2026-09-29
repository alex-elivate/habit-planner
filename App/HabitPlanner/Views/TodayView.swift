import HabitKit
import SwiftUI

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
        adding = nil
        showingSettings = false
        // A row, not the section. A list scrolls to rows reliably and to sections not at all.
        let target: AnyHashable = model.habits(in: routine).first.map { AnyHashable($0.habit.id) }
            ?? AnyHashable(AddHabitRow.scrollID(routine))
        withAnimation { proxy.scrollTo(target, anchor: .top) }
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
        .navigationDestination(for: UUID.self) { HabitDetailView(habitID: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
            }
        }
        .sheet(item: $adding) { routine in
            NavigationStack { HabitEditorView(mode: .new(routine)) }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
        }
        // First launch: walk through both routines. Only when nothing at all is stored, so
        // somebody who skipped it sees it again rather than an empty screen, and it never
        // appears over habits.
        .sheet(isPresented: $firstLaunch) {
            NavigationStack { RoutineSetupView(routine: .morning, then: .evening) }
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
