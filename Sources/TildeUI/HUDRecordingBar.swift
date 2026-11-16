import AppKit
import SwiftUI

/// Record's accessory bar under the HUD, while recording mode is on: what the next clip
/// records, which starts choosing it, then Play or Pause and Stop. The source button has
/// a fixed width, so the bar keeps its width in every state of the clip.
struct HUDRecordingBar: View {
    /// The source button's width, which the source dropdown's rows share.
    static let sourceWidth: CGFloat = 200

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
            // A clip keeps its source until Stop. No tooltip: it would cover the dropdown or the picker.
            HUDButton(
                image: sourceImage(size), title: sourceName, opensBelow: true, width: Self.sourceWidth, isActive: controller.isPickingWindow,
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

/// While a click on screen chooses the source: a dropdown under the source button with the two
/// ways to choose. "Select on screen" has the check mark; "Use window picker" opens the source
/// picker in its place. Esc, the source button and a choice close it.
struct HUDSourceDropdown: View {
    /// From the recording bar's leading end to the dropdown, so its rows line up with the
    /// source button above them.
    static let leadingInset = HUDAccessory.size.endInset - padding
    private static let padding = HUDAccessory.size.scaled(4)

    let onUsePicker: () -> Void

    var body: some View {
        let size = HUDAccessory.size
        VStack(spacing: size.scaled(2)) {
            // The current way to choose: selected, with nothing to do.
            HStack(spacing: size.scaled(4)) {
                HUDButtonLabel(image: Image(systemName: "cursorarrow"), title: "Select on screen", fillsWidth: true)
                Image(systemName: "checkmark")
                    .font(.system(size: size.font(10.5), weight: .semibold))
            }
            .modifier(HUDButtonChrome(width: HUDRecordingBar.sourceWidth, isOn: true, padding: 10))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Select on screen")
            .accessibilityAddTraits(.isSelected)

            HUDButton(image: Image(systemName: "square.grid.2x2"), title: "Use window picker", width: HUDRecordingBar.sourceWidth, help: "Show screens and windows") {
                onUsePicker()
            }
        }
        .padding(Self.padding)
        .hudCard(cornerRadius: size.scaled(12))
        .environment(\.pillSize, size)
        .environment(\.colorScheme, .dark)
    }
}
