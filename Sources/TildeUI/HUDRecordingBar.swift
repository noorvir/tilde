import AppKit
import SwiftUI

/// Record's accessory bar under the HUD, while recording mode is on: what the next clip
/// records, which opens the source picker, then Play or Pause and Stop. The source button has
/// a fixed width, so the bar keeps its width in every state of the clip.
struct HUDRecordingBar: View {
    @ObservedObject var controller: AnnotationController
    /// The name of what Record records, such as "Studio Display".
    let sourceName: String
    let source: RecordingSource
    /// A window's app icon, in place of the window symbol; nil for a screen or a phone.
    let appIcon: NSImage?
    /// The in-app key that records, pauses and resumes, for the tooltip of Play and Pause.
    let recordKeys: [String]

    var body: some View {
        let size = HUDAccessory.size
        HStack(spacing: size.scaled(4)) {
            // A clip keeps its source until Stop. No tooltip: it would cover the picker.
            HUDButton(
                image: sourceImage(size), title: sourceName, opensBelow: true, width: 200, isActive: controller.isPickingWindow,
                showsTooltip: false, help: "Choose source"
            ) {
                controller.dispatch(.pickSource)
            }
            .disabled(!controller.accepts(.pickSource))

            HUDBarDivider()

            HUDButton(image: Image(systemName: isRecording ? "pause.fill" : "record.circle"), keys: recordKeys, help: recordHelp) {
                controller.dispatch(.record)
            }
            .disabled(!controller.accepts(.record))

            HUDButton(image: Image(systemName: "stop.fill"), help: "Stop recording") {
                controller.dispatch(.stop)
            }
            .disabled(!controller.accepts(.stop))
        }
    }

    private var isRecording: Bool {
        controller.recording == .recording
    }

    /// Record starts a clip; while it records the same button pauses it, and resumes it.
    private var recordHelp: String {
        switch controller.recording {
        case .recording: "Pause"
        case .paused: "Resume"
        default: "Record"
        }
    }

    /// The window's app icon, at the size of the symbols beside it; else the symbol of the
    /// source.
    private func sourceImage(_ size: PillSize) -> Image {
        if let appIcon {
            let side = size.scaled(18)
            let sized = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                appIcon.draw(in: rect)
                return true
            }
            return Image(nsImage: sized)
        }
        switch source {
        case .screen: return Image(systemName: "display")
        case .window: return Image(systemName: "macwindow")
        case .phone: return Image(systemName: "iphone")
        }
    }
}
