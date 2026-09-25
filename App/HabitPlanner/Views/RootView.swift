import HabitKit
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(ReminderSettings.self) private var reminders
    @Environment(HealthService.self) private var health
    @Environment(\.scenePhase) private var scenePhase

    @State private var running: RoutineSlot?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            TodayView(start: { running = $0 })
        }
        .fullScreenCover(item: $running, onDismiss: refresh) { routine in
            RunnerView(routine: routine)
        }
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
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
        // Initial as well, because a reminder tapped on a cold launch can set this before the
        // view first observes it, and a change that happened earlier never fires.
        .onChange(of: router.requestedRoutine, initial: true) { _, routine in
            guard let routine else { return }
            router.requestedRoutine = nil
            running = routine
        }
        // A widget tap. It can only ask for a routine, so that is all this reads from it.
        .onOpenURL { url in
            guard let routine = WidgetLink.routine(from: url) else { return }
            running = routine
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            // Midnight, a time zone change, or a clock change. Today may be a different day.
            refresh()
        }
    }

    private func refresh() {
        Task { await model.refresh(health: health, reminders: reminders) }
    }
}
