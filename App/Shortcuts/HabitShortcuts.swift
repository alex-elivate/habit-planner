import AppIntents

/// The phrases Siri and Spotlight offer without any setup. iPhone and watch alike.
///
/// Only in the two apps. The widget extension compiles the intents for its button but must not
/// declare a second set of shortcuts.
struct HabitShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRoutineIntent(),
            phrases: [
                "Start my \(\.$routine) routine in \(.applicationName)",
                "Start \(\.$routine) routine in \(.applicationName)",
                "Begin my \(\.$routine) routine with \(.applicationName)",
            ],
            shortTitle: "Start Routine",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: CompleteCurrentHabitIntent(),
            phrases: [
                "Mark my habit done in \(.applicationName)",
                "Done with my \(\.$routine) habit in \(.applicationName)",
                "Next habit done in \(.applicationName)",
            ],
            shortTitle: "Mark Habit Done",
            systemImageName: "checkmark.circle"
        )
        AppShortcut(
            intent: NextHabitIntent(),
            phrases: [
                "What's next in \(.applicationName)",
                "What's next in my \(\.$routine) routine in \(.applicationName)",
            ],
            shortTitle: "What's Next",
            systemImageName: "list.bullet"
        )
    }
}
