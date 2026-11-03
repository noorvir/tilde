import SwiftUI

/// A remote machine: the laptop symbol with its status dot, as on the Agents page and in the HUD.
struct MachineIcon: View {
    let dot: NodeSetup.Dot
    /// The icon's square; the symbol and the dot scale with it.
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: "laptopcomputer")
            .font(.system(size: size * 2 / 3))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(dot.color)
                    .frame(width: size * 0.3, height: size * 0.3)
                    .offset(x: size / 8, y: -size / 24)
            }
            .help(dot.reason)
            .accessibilityLabel(dot.reason)
    }
}

extension NodeSetup.Dot {
    var color: Color {
        switch self {
        case .green: .green
        case .yellow: .yellow
        case .grey: .gray
        case .red: .red
        }
    }
}
