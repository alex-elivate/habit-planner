import SwiftUI

/// What the last swipe, or count from Health, did, with a way to take it back, along the
/// bottom for a few seconds from when it first shows.
///
/// A full swipe is easy to make by accident, and the row it changed can move or change state
/// out from under the finger. This says what happened in words and undoes it in one tap.
struct UndoBar: ViewModifier {
    @Environment(AppModel.self) private var model

    /// Whether another screen or an alert is over this one. The bar waits, and its few seconds
    /// do not start, until it can be seen.
    private var isCovered: Bool { !model.coveringScreens.isEmpty || model.failure != nil }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                // Only while the offer would still do something: a habit changed again since
                // has nothing left to undo.
                if !isCovered, let offer = model.undoOffer, model.isStillUndoable(offer) {
                    let message = model.undoMessage(for: offer)
                    HStack(spacing: 16) {
                        Text(message)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Undo") { Task { await model.undo(offer) } }
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("undo")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 8, y: 2)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(offer.id)
                    .task(id: offer.id) {
                        guard let shown = model.showing(offer) else { return }
                        // Once, not again each time a screen over the bar closes.
                        if shown.isFirst {
                            AccessibilityNotification.Announcement("\(message). Undo available.").post()
                        }
                        try? await Task.sleep(for: .seconds(max(0, shown.expires.timeIntervalSinceNow)))
                        guard !Task.isCancelled, model.undoOffer?.id == offer.id else { return }
                        model.undoOffer = nil
                    }
                }
            }
            .animation(.snappy, value: model.undoOffer)
    }
}

/// Marks a screen that hides the undo bar while it is up: a sheet, or a screen pushed over
/// the one with the bar.
private struct CoversUndoBar: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { model.coveringScreens.insert(id) }
            .onDisappear { model.coveringScreens.remove(id) }
    }
}

extension View {
    /// The undo bar.
    func undoBar() -> some View { modifier(UndoBar()) }

    /// Holds the undo bar back while this screen is up.
    func coversUndoBar() -> some View { modifier(CoversUndoBar()) }
}
