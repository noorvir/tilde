import AppKit
import SwiftUI

/// After Save video: where the file went, with Show in Finder and Copy.
struct SavedVideoToast: View {
    let video: URL

    var body: some View {
        HStack(spacing: 12) {
            ToastLabel(symbol: "checkmark.circle.fill", tint: .green, title: "Video saved", subtitle: "Downloads")
            HStack(spacing: 4) {
                PillTextButton(title: "Show in Finder", isDestructive: false) {
                    NSWorkspace.shared.activateFileViewerSelecting([video])
                }
                PillTextButton(title: "Copy", isDestructive: false) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([video as NSURL])
                }
            }
        }
        .pillInsets(.regular, leading: .text)
        .pill()
        .environment(\.colorScheme, .dark)
    }
}
