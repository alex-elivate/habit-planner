import HabitKit
import SwiftUI

struct TodayView: View {
    @Environment(AppModel.self) private var model
    let start: (RoutineSlot) -> Void

    @State private var adding: RoutineSlot?
    @State private var showingSettings = false

    var body: some View {
        List {
            Section {
                TodaySummary(progress: ScoreEngine.todayProgress(for: model.histories),
                             score: ScoreEngine.score(for: model.histories))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            ForEach(RoutineSlot.allCases) { routine in
                RoutineSection(routine: routine, start: start, add: { adding = routine })
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

struct ProgressRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.snappy, value: fraction)
        }
    }
}
