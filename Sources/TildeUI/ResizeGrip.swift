import SwiftUI

/// The small diagonal lines at a panel's lower right corner, which resize it like a window's
/// corner. `onChanged` gets the drag's distance since it began.
struct ResizeGrip: View {
    let onChanged: (CGSize) -> Void
    let onEnded: () -> Void

    var body: some View {
        Path { path in
            for inset in [3.0, 7.0] {
                path.move(to: CGPoint(x: 11, y: inset))
                path.addLine(to: CGPoint(x: inset, y: 11))
            }
        }
        .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        .frame(width: 12, height: 12)
        .padding(6)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { onChanged($0.translation) }
                .onEnded { _ in onEnded() }
        )
    }
}
