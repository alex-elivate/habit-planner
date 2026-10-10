import HabitKit
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(ReminderSettings.self) private var reminders
    @Environment(HealthService.self) private var health
    @Environment(\.scenePhase) private var scenePhase

    /// The routine a reminder, the widget or Siri asked for.
    @State private var focus: RoutineSlot?
    @State private var path = NavigationPath()

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            TodayView(focus: $focus)
        }
        .environment(\.healthMatch, HealthMatch(find: healthMatch))
        .alert("Something went wrong", isPresented: Binding(
            get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.failure ?? "")
        }
        .task {
            model.observeRemoteChanges()
            await model.refresh(health: health, reminders: reminders)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-PostTestReminder") {
                // Seeded habits arrive just after the first load.
                try? await Task.sleep(for: .seconds(2))
                await model.reload()
                await ReminderScheduler.postTestReminder(for: .morning, model: model)
            }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
        // Initial as well, because a reminder tapped on a cold launch can set this before the
        // view first observes it, and a change that happened earlier never fires.
        .onChange(of: router.requestedRoutine, initial: true) { _, routine in
            guard let routine else { return }
            router.requestedRoutine = nil
            show(routine)
        }
        // A widget tap. It can only ask for a routine, so that is all this reads from it.
        .onOpenURL { url in
            guard let routine = WidgetLink.routine(from: url) else { return }
            show(routine)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            // Midnight, a time zone change, or a clock change. Today may be a different day.
            refresh()
        }
    }

    /// Back to Today, scrolled to `routine`, with what the store says now.
    private func show(_ routine: RoutineSlot) {
        path = NavigationPath()
        focus = routine
        refresh()
    }

    /// The first time Health shows for a linked habit today, if it does.
    private func healthMatch(_ habitID: UUID) async -> Date? {
        guard let binding = model.bindings[habitID],
              let routine = model.history(for: habitID)?.habit.routine else { return nil }
        let interval = DateInterval(start: model.today.start(in: model.timeZone), end: .now)
        guard let found = try? await health.signalInstants(for: binding, in: interval) else { return nil }
        // One dose linked in both routines belongs to one of them. See `HealthMatching`.
        return HealthMatching.instants(
            found, for: routine, signal: binding.signal,
            sharedAcrossRoutines: (model.sharedReadings[HealthMatching.key(binding)]?.count ?? 0) > 1,
            in: model.timeZone
        ).min()
    }

    private func refresh() {
        Task { await model.refresh(health: health, reminders: reminders) }
    }
}
