import SwiftUI

/// Two screens with the same layout, for the UX specs: the file /tmp/tilde-ux-screen says which.
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
            .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
                screen = (try? String(contentsOfFile: "/tmp/tilde-ux-screen", encoding: .utf8)) ?? "first"
            }
        }
    }
}
