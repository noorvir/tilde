// WIP design mocks: the full flow of the camera bubble (option C, with a camera button in the
// recording bar). Not part of the contract tests.
//   tilde-state demo-flow <out folder>
@testable import TildeUI
import AppKit
import SwiftUI

@MainActor
enum DemoFlow {
    static func run(out: URL) async throws {
        _ = try? await Surfaces.warmUp()
        let ready = try await DemoMocks.hud(["recording": "ready"], client: "Codex")
        let recording = try await DemoMocks.hud(["recording": "recording"], client: "Codex")
        let paused = try await DemoMocks.hud(["recording": "paused"], client: "Codex")
        let clip = try await DemoMocks.hud(["recording": "ready", "clip": true, "notes": 1], client: "Codex")

        try await DemoMocks.page(
            "Camera bubble 1/3: turn on and set up",
            "A camera button in the recording bar, right of Record. The bubble's own bar sets camera, mic, shape and size.",
            scenes: [
                Scene(caption: "1  Camera off: the recording bar has the new camera button, right of Record.") {
                    FlowScene(hud: ready, bar: MockBar(clip: .ready, camera: false), bubble: nil)
                },
                Scene(caption: "2  Click the camera button: it turns on (grey fill) and the bubble shows at once, with its bar.") {
                    FlowScene(hud: ready, bar: MockBar(clip: .ready, camera: true), bubble: BubbleSetup(controls: .plain))
                },
                Scene(caption: "3  Camera menu: choose the camera. The bubble shows the new picture at once.") {
                    FlowScene(hud: ready, bar: MockBar(clip: .ready, camera: true), bubble: BubbleSetup(controls: .cameraMenu))
                },
                Scene(caption: "4  Mic menu: turn the mic on or off, and choose the mic. Off shows a crossed-out mic.") {
                    FlowScene(hud: ready, bar: MockBar(clip: .ready, camera: true), bubble: BubbleSetup(controls: .micMenu))
                },
            ],
            to: out.appendingPathComponent("camera-flow-1-setup.png")
        )

        try await DemoMocks.page(
            "Camera bubble 2/3: shape, size, move, record",
            "The bubble's bar shows only before recording and while paused. The bubble stays in the clip.",
            scenes: [
                Scene(caption: "5  Shape and size: shape switches circle and rounded square; size goes small, medium, large.") {
                    FlowScene(hud: ready, bar: MockBar(clip: .ready, camera: true), bubble: BubbleSetup(shape: .rounded, side: 176, controls: .plain))
                },
                Scene(caption: "6  Move: drag the bubble anywhere on the recorded screen. Its bar hides while you drag.") {
                    FlowScene(hud: ready, bar: MockBar(clip: .ready, camera: true), bubble: BubbleSetup(controls: .none, dragging: true))
                },
                Scene(caption: "7  Recording: the bubble's bar hides; the bubble stays where you put it. The camera button stays.") {
                    FlowScene(hud: recording, bar: MockBar(clip: .recording, camera: true), bubble: BubbleSetup(controls: .none, placed: true))
                },
                Scene(caption: "8  Paused: Resume in the bar. The bubble's bar comes back, to change mic or size before you resume.") {
                    FlowScene(hud: paused, bar: MockBar(clip: .paused, camera: true), bubble: BubbleSetup(controls: .plain, placed: true))
                },
            ],
            to: out.appendingPathComponent("camera-flow-2-record.png")
        )

        try await DemoMocks.page(
            "Camera bubble 3/3: stop, save, camera off",
            "After Stop the clip is a note, as today. Send has two ways: send to the agent, or save a video file.",
            scenes: [
                Scene(caption: "9  After Stop: Send opens \u{201C}Send to Codex\u{201D} or \u{201C}Save video\u{201D}.") {
                    FlowScene(hud: clip, bar: MockBar(clip: .ready, camera: true), bubble: BubbleSetup(controls: .plain, placed: true)) {
                        SendMenuC().padding(.top, -38)
                    }
                },
                Scene(caption: "10  Save video: the MP4 goes to Movies/Tilde. The toast shows it in Finder or copies the file.") {
                    FlowScene(hud: clip, bar: MockBar(clip: .ready, camera: true), bubble: BubbleSetup(controls: .plain, placed: true)) {
                        SavedToast().padding(.top, 6)
                    }
                },
                Scene(caption: "11  Camera off: \u{00D7} on the bubble's bar, or the camera button.") {
                    FlowScene(hud: clip, bar: MockBar(clip: .ready, camera: true), bubble: BubbleSetup(controls: .plain, placed: true, pointerOnClose: true))
                },
                Scene(caption: "12  The bubble goes; the camera button is off. Mic and camera stop, so the Mac's camera light goes out.") {
                    FlowScene(hud: clip, bar: MockBar(clip: .ready, camera: false), bubble: nil)
                },
            ],
            to: out.appendingPathComponent("camera-flow-3-finish.png")
        )
    }
}

// MARK: Scene

struct BubbleSetup {
    enum Controls { case none, plain, cameraMenu, micMenu }

    var shape: BubbleShape = .circle
    var side: CGFloat = 132
    var controls: Controls
    var dragging = false
    /// Where the user moved it in step 6; else the bottom-left corner.
    var placed = false
    var pointerOnClose = false
}

struct FlowScene<Below: View>: View {
    let hud: CGImage
    let bar: MockBar
    let bubble: BubbleSetup?
    @ViewBuilder var below: () -> Below

    init(hud: CGImage, bar: MockBar, bubble: BubbleSetup?, @ViewBuilder below: @escaping () -> Below = { EmptyView() }) {
        self.hud = hud
        self.bar = bar
        self.bubble = bubble
        self.below = below
    }

    var body: some View {
        ZStack(alignment: .top) {
            Desktop()
            if let bubble {
                if bubble.dragging {
                    // Where it was, and where the drag has it now.
                    Circle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: bubble.side, height: bubble.side)
                        .padding(22)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    CameraBubble(shape: bubble.shape, side: bubble.side)
                        .scaleEffect(1.04)
                        .overlay { Pointer(symbol: "hand.raised.fill").offset(x: 8, y: 10) }
                        .offset(x: 600, y: 250)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    if bubble.placed {
                        BubbleWithControls(setup: bubble)
                            .offset(x: 600, y: 250)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else {
                        BubbleWithControls(setup: bubble)
                            .padding(22)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                }
            }
            VStack(spacing: 0) {
                Image(decorative: hud, scale: CGFloat(Renderer.scale))
                    .frame(width: 600, height: 64, alignment: .top)
                    .clipped()
                bar.padding(.top, 2)
                below()
            }
            .frame(width: 600)
            .environment(\.colorScheme, .dark)
        }
    }
}

struct Pointer: View {
    var symbol = "cursorarrow"
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(symbol == "cursorarrow" ? .black : .white)
            .shadow(color: symbol == "cursorarrow" ? .white : .black, radius: 0.5)
            .shadow(color: symbol == "cursorarrow" ? .white : .black.opacity(0.6), radius: 1)
    }
}

// MARK: Recording bar with the camera button

struct MockBar: View {
    enum Clip { case ready, recording, paused }
    let clip: Clip
    let camera: Bool

    var body: some View {
        let size = HUDAccessory.size
        HStack(spacing: size.scaled(4)) {
            HUDButton(image: Image(systemName: "display"), title: "Studio Display", opensBelow: true, width: HUDRecordingBar.sourceWidth, showsTooltip: false, help: "") {}
                .disabled(clip != .ready)
            HUDBarDivider()
            HUDButton(image: Image(systemName: clip == .recording ? "pause.fill" : "record.circle"), help: "") {}
            HUDButton(image: Image(systemName: camera ? "video.fill" : "video"), isOn: camera, help: camera ? "Turn camera off" : "Turn camera on") {}
            HUDButton(image: Image(systemName: "stop.fill"), help: "") {}
                .disabled(clip == .ready)
        }
        .pillInsets(size)
        .pill()
        .environment(\.colorScheme, .dark)
    }
}

// MARK: The bubble's bar and menus

struct BubbleWithControls: View {
    let setup: BubbleSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CameraBubble(shape: setup.shape, side: setup.side)
            if setup.controls != .none {
                BubbleBar(setup: setup)
                    .overlay(alignment: .bottomLeading) {
                        switch setup.controls {
                        case .cameraMenu:
                            CameraMenu().padding(.bottom, 40).padding(.leading, 0).fixedSize()
                        case .micMenu:
                            MicMenu().padding(.bottom, 40).padding(.leading, 34).fixedSize()
                        default:
                            EmptyView()
                        }
                    }
            }
        }
    }
}

struct BubbleBar: View {
    let setup: BubbleSetup

    var body: some View {
        let size = HUDAccessory.size
        HStack(spacing: size.scaled(2)) {
            device("video.fill", isOpen: setup.controls == .cameraMenu)
            device("mic.fill", isOpen: setup.controls == .micMenu)
            HUDBarDivider()
            HUDButton(image: Image(systemName: setup.shape == .circle ? "circle" : "app"), help: "Shape") {}
            HUDButton(image: Image(systemName: setup.side > 140 ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"), help: "Size") {}
            HUDBarDivider()
            HUDButton(image: Image(systemName: "xmark"), help: "Turn camera off") {}
                .overlay {
                    if setup.pointerOnClose {
                        Pointer().offset(x: 9, y: 11)
                    }
                }
        }
        .pillInsets(size)
        .pill()
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    /// An icon with a chevron: it opens the device menu above the bar.
    private func device(_ symbol: String, isOpen: Bool) -> some View {
        HUDButtonLabel(image: Image(systemName: symbol), opensBelow: true)
            .modifier(HUDButtonChrome(isActive: isOpen, padding: 6))
    }
}

struct CameraMenu: View {
    var body: some View {
        DeviceCard {
            ToggleRow(symbol: "video", title: "FaceTime HD Camera", isOn: true, width: 250)
            ToggleRow(symbol: "video", title: "Studio Display Camera", isOn: false, width: 250)
            ToggleRow(symbol: "iphone", title: "iPhone Camera", detail: "Continuity", isOn: false, width: 250)
        }
    }
}

struct MicMenu: View {
    var body: some View {
        DeviceCard {
            ToggleRow(symbol: "mic", title: "Record microphone", isOn: true, width: 250)
            Rectangle().fill(.white.opacity(0.1)).frame(width: 230, height: 1).padding(.vertical, 3)
            ToggleRow(symbol: "laptopcomputer", title: "MacBook Pro Microphone", isOn: true, width: 250)
            ToggleRow(symbol: "display", title: "Studio Display Microphone", isOn: false, width: 250)
            ToggleRow(symbol: "airpodspro", title: "AirPods Pro", isOn: false, width: 250)
        }
    }
}

struct DeviceCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        let size = HUDAccessory.size
        VStack(spacing: size.scaled(2)) { content() }
            .padding(size.scaled(4))
            .hudCard(cornerRadius: size.scaled(12))
            .environment(\.pillSize, size)
            .environment(\.colorScheme, .dark)
    }
}
