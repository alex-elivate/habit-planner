import AppIntents
import HabitKit
import SwiftUI
import WidgetKit

/// Every family, iPhone and watch. Tapping any of them opens the runner on the routine shown.
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
            VStack(alignment: .leading, spacing: 12) {
                ForEach(glance.routines, id: \.routine) { routine in
                    // Each part links on its own, never around the Done button. A button nested
                    // in a Link can lose its tap to the Link and open the app instead.
                    VStack(alignment: .leading, spacing: 10) {
                        NextHabitView(routine: routine, link: WidgetLink.url(for: routine.routine))
                        Link(destination: WidgetLink.url(for: routine.routine)) {
                            UnlockView(routine: routine)
                        }
                    }
                    if routine.routine != glance.routines.last?.routine { Divider() }
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

/// The routine's next habit and how far through today it is. The runner's first screen.
private struct NextHabitView: View {
    let routine: RoutineGlance
    /// Where the text leads, when the widget has more than one routine to link to. The Done
    /// button always sits outside it.
    var link: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            linked {
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
                    } else {
                        Text(routine.doneText).font(.headline)
                    }
                }
            }

            Spacer(minLength: 0)

            if routine.nextHabitTitle != nil {
                #if os(iOS)
                // Runs in the app, which ticks the habit next in sequence and reloads this
                // widget. See `CompleteCurrentHabitIntent`.
                Button(intent: CompleteCurrentHabitIntent(routine: routine.routine)) {
                    Label("Done", systemImage: "checkmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .accessibilityIdentifier("widget.done.\(routine.routine.rawValue)")
                #endif
            }

            HStack(spacing: 6) {
                Gauge(value: routine.progress.fraction) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(.accentColor)
                Text(routine.progressText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func linked(@ViewBuilder _ content: () -> some View) -> some View {
        if let link {
            Link(destination: link, label: content)
        } else {
            content()
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
                Gauge(value: assessment.repetitionProgress) { EmptyView() }
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
            let blocker: String
            switch assessment.decision {
            case .open, .blocked(.notEnoughHistory):
                blocker = "\(min(assessment.elapsedOccurrences, assessment.requiredOccurrences)) of \(assessment.requiredOccurrences)"
            case .blocked(.rateTooLow):
                blocker = "needs \(Int((assessment.requiredRate * 100).rounded()))%"
            case .blocked(.recentDoubleMiss):
                blocker = "missed twice"
            }
            if let planned { return "\(planned) next · \(title) \(blocker)" }
            return "\(title) bedding in · \(blocker)"
        case .unavailable:
            return "Update the app to see progress"
        }
    }
}
