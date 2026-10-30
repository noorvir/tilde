import SwiftUI

/// Two screens with the same layout, for the UX specs: tildeux://first and tildeux://second.
@main
struct TwoScreens: App {
    @State private var screen = "first"

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(1...14, id: \.self) { row in
                        Text(screen == "first" ? "Starlink outages disrupt drones \(row)" : "Museum opens a wing for painters \(row)")
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .navigationTitle(screen.capitalized)
            }
            .onOpenURL { screen = $0.host() ?? "first" }
        }
    }
}
