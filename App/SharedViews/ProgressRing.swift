import SwiftUI

struct ProgressRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 8

    var body: some View {
        // A stroke is centred on its path, so the circle is inset by half the line to keep the
        // whole ring inside the frame. Otherwise a list row clips its outer edge.
        ZStack {
            Circle().inset(by: lineWidth / 2).stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .inset(by: lineWidth / 2)
                .trim(from: 0, to: fraction)
                .stroke(.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.snappy, value: fraction)
        }
    }
}
