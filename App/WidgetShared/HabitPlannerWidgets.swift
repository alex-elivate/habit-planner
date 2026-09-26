import SwiftUI
import WidgetKit

/// The widget extension. One per platform, built from this same folder.
@main
struct HabitPlannerWidgets: WidgetBundle {
    var body: some Widget {
        GlanceWidget()
    }
}

/// The routine at a glance: the next habit, today's progress, and what the routine unlocks next.
///
/// Read only. Tapping opens the runner on the routine shown, and ticking a habit from the
/// widget itself waits for App Intents in Phase 6.
struct GlanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetLink.glanceKind, provider: GlanceProvider()) { entry in
            GlanceView(entry: entry)
        }
        .configurationDisplayName("Routine")
        .description("Your next habit, today's progress, and what unlocks next.")
        .supportedFamilies(Self.families)
    }

    private static var families: [WidgetFamily] {
        #if os(watchOS)
        [.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner]
        #elseif os(macOS)
        [.systemSmall, .systemMedium, .systemLarge]
        #else
        [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #endif
    }
}
