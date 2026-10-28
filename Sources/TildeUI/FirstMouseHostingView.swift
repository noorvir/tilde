import SwiftUI

/// Hosting view whose first click acts at once, even when its panel is not key. Annotate
/// mode keeps the overlay key, so without this the first click on Tilde's panels is lost.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
