import SwiftUI

/// Record's accessory bar under the HUD, while recording mode is on: what the next clip
/// records, which opens the source picker, then Play or Pause and Stop. The source button has
/// a fixed width, so the bar keeps its width in every state of the clip.
struct HUDRecordingBar: View {
    @ObservedObject var controller: AnnotationController
    /// The name of what Record records, such as "Studio Display".
    let sourceName: String
    let source: RecordingSource
    /// The in-app key that records, pauses and resumes, for the tooltip of Play and Pause.
    let recordKeys: [String]

    var body: some View {
        let size = HUDAccessory.size
        HStack(spacing: size.scaled(4)) {
            // A clip keeps its source until Stop.
            HUDButton(
                image: Image(systemName: sourceSymbol), title: sourceName, opensBelow: true, width: 200, isActive: controller.isPickingWindow,
                help: "Choose source"
            ) {
                controller.dispatch(.pickSource)
            }
            .disabled(!controller.accepts(.pickSource))

            HUDBarDivider()

            HUDButton(image: Image(systemName: isRecording ? "pause.fill" : "play.fill"), keys: recordKeys, help: recordHelp) {
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

    private var sourceSymbol: String {
        switch source {
        case .screen: "display"
        case .window: "macwindow"
        case .phone: "iphone"
        }
    }
}
