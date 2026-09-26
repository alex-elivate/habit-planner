import SwiftUI

extension View {
    /// A compact navigation title, which is what a sheet on the phone wants.
    ///
    /// Defined per app so the views shared with the Mac need no `#if`. The Mac has no inline
    /// title mode and its version does nothing.
    func inlineNavigationTitle() -> some View {
        navigationBarTitleDisplayMode(.inline)
    }
}
