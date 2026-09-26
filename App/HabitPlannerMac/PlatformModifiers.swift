import SwiftUI

extension View {
    /// The Mac has no inline title mode. See the iPhone app's version.
    func inlineNavigationTitle() -> some View { self }

    /// A Mac sheet sizes itself to its content, and a grouped form asks for very little, so
    /// a shared sheet says how much room it needs. The phone's sheets fill the screen.
    func sheetMinimumSize(width: CGFloat, height: CGFloat) -> some View {
        frame(minWidth: width, minHeight: height)
    }
}
