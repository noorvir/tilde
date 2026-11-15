import AppKit
import SwiftUI

/// Record's accessory bar under the HUD, while recording mode is on: the source menu, for what
/// the next clip records, then Record or Pause and Stop. The source button has a fixed width,
/// so the bar keeps its width in every state of the clip and of choosing.
struct HUDRecordingBar: View {
    @ObservedObject var controller: AnnotationController
    @ObservedObject var sources: SourcePickerModel
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
            // A native menu, as the wireframe bar's style menus. A clip keeps its source until
            // Stop, so the menu is off from Record until then.
            Menu {
                Section("Screens") {
                    ForEach(sources.screens) { tile in
                        Toggle(isOn: Binding(get: { tile.id == source.id }, set: { _ in controller.choose(tile.source) })) {
                            Label {
                                Text(tile.title)
                                if !tile.detail.isEmpty {
                                    Text(tile.detail)
                                }
                            } icon: {
                                Image(systemName: Self.symbol(of: tile.source))
                            }
                        }
                    }
                }
                Divider()
                Button("Select on screen", systemImage: "cursorarrow") {
                    controller.dispatch(.selectOnScreen)
                }
                .disabled(!controller.accepts(.selectOnScreen))
                Button("Show all windows", systemImage: "square.grid.2x2") {
                    controller.dispatch(.showAllWindows)
                }
                .disabled(!controller.accepts(.showAllWindows))
            } label: {
                HUDButtonLabel(image: buttonImage(size), title: buttonTitle, key: isSelectingOnScreen ? "Esc" : nil, opensBelow: true, fillsWidth: true)
                    .modifier(HUDButtonChrome(width: 200, isActive: controller.isPickingWindow, padding: 10))
                    // One button for VoiceOver, not one for each part of the label.
                    .accessibilityElement(children: .combine)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(!controller.accepts(.choose))
            .accessibilityLabel("Source")
            .accessibilityValue(buttonTitle)

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

    /// A click on a window on screen chooses it; Esc stops with no change.
    private var isSelectingOnScreen: Bool {
        controller.isPickingWindow && !controller.isWindowGridOpen
    }

    private var buttonTitle: String {
        isSelectingOnScreen ? "Click a window" : sourceName
    }

    /// Record starts a clip; while it records the same button pauses it, and resumes it.
    private var recordHelp: String {
        switch controller.recording {
        case .recording: "Pause"
        case .paused: "Resume"
        default: "Record"
        }
    }

    /// The pointer while a click on screen chooses; else the window's app icon, at the size of
    /// the symbols beside it, or the symbol of the source.
    private func buttonImage(_ size: PillSize) -> Image {
        if isSelectingOnScreen {
            return Image(systemName: "cursorarrow")
        }
        if let appIcon {
            let side = size.scaled(18)
            let sized = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                appIcon.draw(in: rect)
                return true
            }
            return Image(nsImage: sized)
        }
        return Image(systemName: Self.symbol(of: source))
    }

    private static func symbol(of source: RecordingSource) -> String {
        switch source {
        case .screen: "display"
        case .window: "macwindow"
        case .phone: "iphone"
        }
    }
}
