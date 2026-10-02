import SwiftUI

/// What the last swipe did, with a way to take it back, along the bottom for a few seconds.
///
/// A full swipe is easy to make by accident, and the row it changed can move or change state
/// out from under the finger. This says what happened in words and undoes it in one tap.
struct UndoBar: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let offer = model.undoOffer, offer.expires > .now {
                    HStack(spacing: 16) {
                        Text(offer.message)
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
                        AccessibilityNotification.Announcement("\(offer.message). Undo available.").post()
                        try? await Task.sleep(for: .seconds(max(0, offer.expires.timeIntervalSinceNow)))
                        guard !Task.isCancelled, model.undoOffer?.id == offer.id else { return }
                        model.undoOffer = nil
                    }
                }
            }
            .animation(.snappy, value: model.undoOffer)
    }
}

extension View {
    func undoBar() -> some View { modifier(UndoBar()) }
}
