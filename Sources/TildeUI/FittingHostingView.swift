import AppKit
import SwiftUI

/// Hosting view that reports its fitting size whenever SwiftUI changes its content size,
/// so borderless panels can resize around their content.
final class FittingHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: ((NSSize) -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in
            guard let self, let onSizeChange = self.onSizeChange else {
                return
            }
            onSizeChange(self.fittingSize)
        }
    }
}
