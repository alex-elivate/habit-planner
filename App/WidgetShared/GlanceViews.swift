import AppIntents
import HabitKit
import SwiftUI
import WidgetKit

/// Every family, iPhone and watch. Tapping any of them opens the app on the routine shown.
struct GlanceView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GlanceEntry

    var body: some View {
        switch entry.content {
        case .noStore:
            NoStoreView(family: family, message: "Open the app to set up your routines.")
                .containerBackground(.background, for: .widget)
        case .unreadable:
            NoStoreView(family: family, message: "Could not read your habits. Open the app.")
                .containerBackground(.background, for: .widget)
        case .glance(let glance):
            content(glance)
                .containerBackground(.background, for: .widget)
        }
    }

    @ViewBuilder private func content(_ glance: Glance) -> some View {
        let featured = glance.routine(entry.featured)
        switch family {
        #if os(iOS) || os(macOS)
        case .systemSmall:
            NextHabitView(routine: featured)
                .widgetURL(WidgetLink.url(for: featured.routine))
        case .systemMedium:
            HStack(alignment: .top, spacing: 16) {
                NextHabitView(routine: featured)
                Divider()
                UnlockView(routine: featured)
            }
            .widgetURL(WidgetLink.url(for: featured.routine))
        case .systemLarge:
            // A compact layout of its own. Stacking the medium widget's two columns for each
            // routine ran past the top and bottom of the widget.
            // The space left over goes either side of the divider, so each routine holds its
            // half of the widget rather than both bunching at the top.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(glance.routines, id: \.routine) { routine in
                    LargeRoutineView(routine: routine)
                    if routine.routine != glance.routines.last?.routine {
                        Spacer(minLength: 10)
                        Divider()
                        Spacer(minLength: 10)
                    }
                }
            }
        #endif
        case .accessoryCircular:
            CircularView(routine: featured)
                .widgetURL(WidgetLink.url(for: featured.routine))
        case .accessoryRectangular:
            RectangularView(routine: featured)
                .widgetURL(WidgetLink.url(for: featured.routine))
        case .accessoryInline:
            Text(featured.inlineText)
                .widgetURL(WidgetLink.url(for: featured.routine))
        #if os(watchOS)
        case .accessoryCorner:
            Image(systemName: featured.routine.symbol)
                .font(.title3)
                .widgetLabel {
                    Gauge(value: featured.progress.fraction) {
                        Text(featured.routine.title)
                    } currentValueLabel: {
                        Text("\(featured.remaining)")
                    }
                }
                .widgetURL(WidgetLink.url(for: featured.routine))
        #endif
        default:
            RectangularView(routine: featured)
                .widgetURL(WidgetLink.url(for: featured.routine))
        }
    }
}

// MARK: - Pieces

/// The routine's next habit and how far through today it is.
private struct NextHabitView: View {
    let routine: RoutineGlance

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                Label(routine.routine.title, systemImage: routine.routine.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                if let next = routine.nextHabitTitle {
                    Text("Next").font(.caption2).foregroundStyle(.secondary)
                    Text(next)
                        .font(.headline)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                        // Dims the moment Done is tapped, until the app's new timeline
                        // arrives. The tick itself takes the app a few seconds to write.
                        .invalidatableContent()
                } else {
                    Text(routine.doneText).font(.headline)
                }
            }

            Spacer(minLength: 0)

            if routine.nextHabitTitle != nil {
                DoneButton(routine: routine.routine)
            }

            HStack(spacing: 6) {
                Gauge(value: routine.progress.fraction) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(.accentColor)
                Text(routine.progressText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .invalidatableContent()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


}

/// Ticks the routine's next habit. Runs in the app, which ticks the habit next in sequence and
/// reloads this widget. One intent per routine: see `CompleteMorningStepIntent`.
private struct DoneButton: View {
    let routine: RoutineSlot

    var body: some View {
        #if os(iOS)
        Group {
            switch routine {
            case .morning: Button(intent: CompleteMorningStepIntent()) { label }
            case .evening: Button(intent: CompleteEveningStepIntent()) { label }
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(.accentColor)
        .accessibilityIdentifier("widget.done.\(routine.rawValue)")
        #endif
    }

    private var label: some View {
        Label("Done", systemImage: "checkmark")
            .font(.caption.weight(.semibold))
    }
}

/// One routine in the large widget: its next habit with Done beside it, its progress, and
/// what it adds next, each in a line.
///
/// The text links to the routine and the Done button sits outside the link. A button nested
/// in a Link can lose its tap to the Link and open the app instead.
private struct LargeRoutineView: View {
    let routine: RoutineGlance

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Link(destination: WidgetLink.url(for: routine.routine)) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(routine.routine.title, systemImage: routine.routine.symbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                            Spacer()
                            Text(routine.progressText)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(routine.nextHabitTitle.map { "Next: \($0)" } ?? routine.doneText)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .invalidatableContent()
                    }
                }
                if routine.nextHabitTitle != nil { DoneButton(routine: routine.routine) }
            }

            Gauge(value: routine.progress.fraction) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(.accentColor)
                .invalidatableContent()

            Link(destination: WidgetLink.url(for: routine.routine)) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Next to add: \(routine.planned ?? "not planned yet")",
                          systemImage: routine.unlock == .open ? "lock.open" : "lock")
                    if let waiting = waitingText {
                        Text(waiting).padding(.leading, 22)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the routine is waiting on, shortened to fit one line.
    private var waitingText: String? {
        switch routine.unlock {
        case .open: routine.planned == nil ? "Ready for a new habit." : "Unlocked. Add it in the app."
        case .beddingIn(let title, let assessment): "Waiting on \(title): \(RoutineGlance.blocker(assessment))"
        case .unavailable: "Update the app to see progress."
        }
    }
}

/// How close the routine is to its next habit, and what that habit is planned to be.
private struct UnlockView: View {
    let routine: RoutineGlance

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Next to add", systemImage: routine.unlock == .open ? "lock.open" : "lock")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(routine.planned ?? "Not planned yet")
                .font(.headline)
                .foregroundStyle(routine.planned == nil ? .secondary : .primary)
                .lineLimit(2)

            Spacer(minLength: 0)

            switch routine.unlock {
            case .open:
                Text(routine.planned == nil ? "Ready for a new habit." : "Unlocked. Add it in the app.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .beddingIn(let title, let assessment):
                Gauge(value: assessment.bedInProgress) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(.accentColor)
                Text("\(title): \(assessment.explanation)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            case .unavailable:
                Text("Update the app to see progress.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct CircularView: View {
    let routine: RoutineGlance

    var body: some View {
        Gauge(value: routine.progress.fraction) {
            Image(systemName: routine.routine.symbol)
        } currentValueLabel: {
            if routine.remaining > 0 {
                Text("\(routine.remaining)")
            } else {
                Image(systemName: routine.hasWorkToday ? "checkmark" : "moon.zzz")
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .accessibilityLabel(routine.inlineText)
    }
}

/// The featured routine's next habit, or once it is done, what the routine is working towards.
private struct RectangularView: View {
    let routine: RoutineGlance

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(routine.routine.title, systemImage: routine.routine.symbol)
                .font(.caption2.weight(.semibold))
                .widgetAccentable()
            if let next = routine.nextHabitTitle {
                Text(next).font(.headline).lineLimit(1)
                Text("\(routine.remaining) left · \(routine.progressText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(routine.doneText).font(.headline).lineLimit(1)
                Text(routine.unlockLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct NoStoreView: View {
    let family: WidgetFamily
    let message: String

    var body: some View {
        switch family {
        case .accessoryCircular:
            Image(systemName: "sunrise")
        case .accessoryInline:
            Text("Open Habit Planner")
        default:
            VStack(alignment: .leading, spacing: 4) {
                Label("Habit Planner", systemImage: "sunrise").font(.caption.weight(.semibold))
                Text(message).font(.caption)
            }
        }
    }
}

// MARK: - Wording

extension RoutineGlance {
    var progressText: String {
        progress.total == 0 ? "Nothing due" : "\(progress.completed)/\(progress.total) done"
    }

    var doneText: String {
        hasWorkToday ? "Done for today" : "Nothing due today"
    }

    var inlineText: String {
        if let next = nextHabitTitle { return "\(routine.title): \(next), \(remaining) left" }
        return "\(routine.title): \(doneText.lowercased())"
    }

    /// One line on what the routine is working towards.
    var unlockLine: String {
        switch unlock {
        case .open:
            return planned.map { "\($0) is unlocked" } ?? "Ready for a new habit"
        case .beddingIn(let title, let assessment):
            let blocker = Self.blocker(assessment)
            if let planned { return "\(planned) next · \(title) \(blocker)" }
            return "\(title) bedding in · \(blocker)"
        case .unavailable:
            return "Update the app to see progress"
        }
    }

    /// What holds the habit being judged, in a few words. Past 28 sessions the count can pass
    /// what is needed while the gate is held for another reason, so it names that reason.
    static func blocker(_ assessment: LockInGate.Assessment) -> String {
        switch assessment.decision {
        case .open, .blocked(.notEnoughHistory):
            "\(assessment.completionsLabel) done"
        case .blocked(.rateTooLow):
            "needs \(Int((assessment.requiredRate * 100).rounded()))%"
        case .blocked(.recentDoubleMiss):
            "missed twice"
        }
    }
}
