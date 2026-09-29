import HabitKit
import SwiftUI

/// The pictures a habit can have, and the one it gets until the person picks.
enum HabitIcons {
    /// Every symbol offered. A fixed list, so a name stored by one device is one every device
    /// can draw. A stored name missing from it, from a newer build, draws the suggestion.
    static let symbols = [
        "drop.fill", "cup.and.saucer.fill", "fork.knife", "carrot.fill",
        "pills.fill", "cross.case.fill", "heart.fill", "lungs.fill",
        "bed.double.fill", "alarm.fill", "sunrise.fill", "sun.max.fill",
        "sunset.fill", "moon.fill", "moon.stars.fill", "wind",
        "figure.walk", "figure.run", "figure.yoga", "figure.cooldown",
        "figure.mind.and.body", "dumbbell.fill", "bicycle", "flame.fill",
        "book.fill", "books.vertical.fill", "square.and.pencil", "pencil.and.scribble",
        "brain.head.profile", "leaf.fill", "tree.fill", "pawprint.fill",
        "dog.fill", "house.fill", "sparkles", "washer.fill",
        "shower.fill", "bathtub.fill", "mouth.fill", "comb.fill",
        "tshirt.fill", "calendar", "checklist", "timer",
        "laptopcomputer", "iphone.slash", "music.note", "headphones",
        "paintbrush.fill", "camera.fill", "phone.fill", "envelope.fill",
        "person.2.fill", "star.fill", "bolt.fill", "dollarsign.circle.fill",
        "cart.fill", "key.fill", "car.fill", "hourglass",
    ]

    private static let known = Set(symbols)

    /// Beginnings of words in a title that suggest a picture, checked in order, so "meditate"
    /// is caught before "med". Derived each time rather than stored, so a renamed habit's
    /// suggestion follows its new name.
    private static let suggestions: [(words: [String], symbol: String)] = [
        (["meditat", "breath", "mindful"], "figure.mind.and.body"),
        (["water", "hydrat"], "drop.fill"),
        (["coffee", "tea"], "cup.and.saucer.fill"),
        (["breakfast", "lunch", "dinner", "eat", "cook"], "fork.knife"),
        (["med", "pill", "vitamin", "supplement", "dose"], "pills.fill"),
        (["stretch", "yoga"], "figure.yoga"),
        (["walk", "steps"], "figure.walk"),
        (["run", "jog"], "figure.run"),
        (["gym", "lift", "workout", "exercise", "push"], "dumbbell.fill"),
        (["bike", "cycle"], "bicycle"),
        (["read", "book"], "book.fill"),
        (["journal", "write", "diary"], "square.and.pencil"),
        (["plan", "calendar", "schedule"], "calendar"),
        (["bed", "sleep"], "bed.double.fill"),
        (["teeth", "floss", "brush"], "mouth.fill"),
        (["shower"], "shower.fill"),
        (["bath"], "bathtub.fill"),
        (["dog"], "dog.fill"),
        (["pet", "cat", "feed"], "pawprint.fill"),
        (["clean", "tidy", "dishes"], "sparkles"),
        (["laundry", "wash"], "washer.fill"),
        (["clothes", "outfit", "dress"], "tshirt.fill"),
        (["phone", "screen"], "iphone.slash"),
        (["music", "practice", "piano", "guitar"], "music.note"),
        (["call", "family", "friend"], "phone.fill"),
        (["email", "inbox"], "envelope.fill"),
        (["alarm", "wake"], "alarm.fill"),
    ]

    /// A picture for a habit nobody has picked one for: from its title if a word matches,
    /// otherwise its routine's.
    static func suggested(for title: String, in routine: RoutineSlot) -> String {
        let words = title.lowercased().split { !$0.isLetter }
        for suggestion in suggestions
        where suggestion.words.contains(where: { start in words.contains { $0.hasPrefix(start) } }) {
            return suggestion.symbol
        }
        return routine == .morning ? "sunrise.fill" : "moon.stars.fill"
    }

    /// What to draw for a chosen `symbol`, or the suggestion when there is none this build knows.
    static func symbol(_ symbol: String?, title: String, routine: RoutineSlot) -> String {
        if let symbol, known.contains(symbol) { return symbol }
        return suggested(for: title, in: routine)
    }

    static func symbol(for habit: Habit) -> String {
        symbol(habit.symbolName, title: habit.title, routine: habit.routine)
    }

    static func tint(for habit: Habit) -> HabitTint {
        habit.tint ?? .default(for: habit.routine)
    }
}

extension HabitTint {
    static func `default`(for routine: RoutineSlot) -> HabitTint {
        routine == .morning ? .orange : .indigo
    }

    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .brown: .brown
        case .gray: .gray
        }
    }

    var name: String { rawValue.capitalized }
}

/// A habit's picture, drawn to show where it stands today.
struct HabitIconView: View {
    let symbol: String
    let tint: HabitTint
    var state: StepState = .waiting
    var size: CGFloat = 40

    var body: some View {
        let color = tint.color
        ZStack {
            Circle().fill(background(color))
            if state == .next {
                Circle().strokeBorder(color, lineWidth: 2)
            }
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(foreground(color))
                .symbolEffect(.bounce, value: state == .done)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if let badge {
                Image(systemName: badge)
                    .font(.system(size: size * 0.3, weight: .bold))
                    .foregroundStyle(.white, state == .done ? color : .secondary)
                    .background(Circle().fill(.background).padding(-1))
                    .offset(x: 2, y: 2)
            }
        }
        .opacity(state == .notDue ? 0.45 : 1)
        .animation(.snappy, value: state)
        .accessibilityHidden(true)
    }

    private var badge: String? {
        switch state {
        case .done: "checkmark.circle.fill"
        case .skipped: "forward.circle.fill"
        default: nil
        }
    }

    private func background(_ color: Color) -> AnyShapeStyle {
        switch state {
        case .done: AnyShapeStyle(color)
        case .skipped, .notDue: AnyShapeStyle(.quaternary)
        case .next, .waiting: AnyShapeStyle(color.opacity(0.16))
        }
    }

    private func foreground(_ color: Color) -> AnyShapeStyle {
        switch state {
        case .done: AnyShapeStyle(.white)
        case .skipped, .notDue: AnyShapeStyle(.secondary)
        case .next, .waiting: AnyShapeStyle(color)
        }
    }
}

/// Picks a habit's picture and colour.
struct IconPickerView: View {
    @Binding var symbolName: String?
    @Binding var tint: HabitTint?
    let title: String
    let routine: RoutineSlot

    private var shownSymbol: String { HabitIcons.symbol(symbolName, title: title, routine: routine) }
    private var shownTint: HabitTint { tint ?? .default(for: routine) }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HabitIconView(symbol: shownSymbol, tint: shownTint, size: 72)
                    .padding(.top, 8)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 12)], spacing: 12) {
                    ForEach(HabitTint.allCases, id: \.self) { option in
                        Button {
                            tint = option
                        } label: {
                            Circle().fill(option.color)
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if option == shownTint {
                                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.name)
                        .accessibilityAddTraits(option == shownTint ? .isSelected : [])
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 12)], spacing: 12) {
                    ForEach(HabitIcons.symbols, id: \.self) { symbol in
                        Button {
                            symbolName = symbol
                        } label: {
                            HabitIconView(symbol: symbol, tint: shownTint,
                                          state: symbol == shownSymbol ? .next : .waiting, size: 48)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(symbol.replacingOccurrences(of: ".fill", with: "")
                            .replacingOccurrences(of: ".", with: " "))
                        .accessibilityAddTraits(symbol == shownSymbol ? .isSelected : [])
                    }
                }

                if symbolName != nil || tint != nil {
                    Button("Use the suggested icon") {
                        symbolName = nil
                        tint = nil
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Icon")
        .inlineNavigationTitle()
    }
}
