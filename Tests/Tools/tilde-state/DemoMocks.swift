// WIP design mocks for demo recordings with a camera bubble. Not part of the contract tests.
//   tilde-state demo-mocks <out folder>
@testable import TildeUI
import AppKit
import SwiftUI

@MainActor
enum DemoMocks {
    static let sceneSize = CGSize(width: 820, height: 470)

    static func run(out: URL) async throws {
        _ = try? await Surfaces.warmUp()
        let codexReady = try await hud(["recording": "ready"], client: "Codex")
        let picking = try await hud(["recording": "ready", "pickingWindow": true], client: "Codex")
        let demoReady = try await hud(["recording": "ready"], client: "Demo video", demo: true, save: true)
        let demoRecording = try await hud(["recording": "recording"], client: "Demo video", demo: true, save: true)
        let demoPaused = try await hud(["recording": "paused"], client: "Demo video", demo: true, save: true)
        let codexRecording = try await hud(["recording": "recording"], client: "Codex")

        // A: Camera and Microphone in the source dropdown. Camera on makes the clip a demo.
        try await page(
            "Option A: camera and mic in the source dropdown",
            "Camera on = demo clip. Stop saves an MP4 file; it does not go to the agent.",
            scenes: [
                Scene(caption: "1  Ready: the source dropdown has Camera and Microphone. The bubble shows at once as a preview.") {
                    SceneBody(hud: picking, hudHeight: 106, bubble: .circle) {
                        DropdownA()
                    }
                },
                Scene(caption: "2  Recording: bubble in the bottom-left corner, drag to move. HUD says \u{201C}for Demo video\u{201D}; Send is Save.") {
                    SceneBody(hud: demoRecording, hudHeight: 106, bubble: .circle) { EmptyView() }
                },
                Scene(caption: "3  After Stop: the file is saved to Movies/Tilde. Show it in Finder or copy it to paste in Slack.") {
                    SceneBody(hud: demoReady, hudHeight: 106, bubble: .circle) { SavedToast().padding(.top, 6) }
                },
            ],
            to: out.appendingPathComponent("demo-camera-A-source-dropdown.png")
        )

        // B: the destination in the HUD subtitle: an agent, or a demo video with camera and mic.
        try await page(
            "Option B: choose \u{201C}Demo video\u{201D} as the destination",
            "Click \u{201C}for Codex\u{201D} in the HUD. Demo video turns on camera and mic. The recording bar does not change.",
            scenes: [
                Scene(caption: "1  Ready: the subtitle opens a card: send to the agent, or save a demo video with camera and mic.") {
                    SceneBody(hud: codexReady, hudHeight: 64, bubble: nil) {
                        DestinationCardB().padding(.top, 2)
                    }
                },
                Scene(caption: "2  Recording: rounded bubble, bottom-right. Camera and mic stay in the card under the subtitle.") {
                    SceneBody(hud: demoRecording, hudHeight: 106, bubble: .rounded, corner: .bottomTrailing) { EmptyView() }
                },
                Scene(caption: "3  Paused: the clip so far. Save writes the MP4 to Movies/Tilde and shows the toast.") {
                    SceneBody(hud: demoPaused, hudHeight: 106, bubble: .rounded, corner: .bottomTrailing) { SavedToast().padding(.top, 6) }
                },
            ],
            to: out.appendingPathComponent("demo-camera-B-destination.png")
        )

        // C: the bubble carries its own controls; the dropdown only shows or hides it.
        try await page(
            "Option C: the bubble carries its own controls",
            "\u{201C}Show camera\u{201D} in the source dropdown. Mic, shape and size are on the bubble. Choose Send or Save after Stop.",
            scenes: [
                Scene(caption: "1  Ready: hover the bubble for mic, shape, size and close. The HUD stays for Codex.") {
                    SceneBody(hud: codexReady, hudHeight: 106, bubble: .circle, bubbleControls: true) { EmptyView() }
                },
                Scene(caption: "2  Recording: the bubble controls hide. The clip is a normal Tilde clip.") {
                    SceneBody(hud: codexRecording, hudHeight: 106, bubble: .circle) { EmptyView() }
                },
                Scene(caption: "3  After Stop: Send has a menu. \u{201C}Save video\u{201D} makes a file instead of a report.") {
                    SceneBody(hud: codexReady, hudHeight: 64, bubble: .circle) {
                        SendMenuC().padding(.top, -4)
                    }
                },
            ],
            to: out.appendingPathComponent("demo-camera-C-bubble-controls.png")
        )
    }

    // MARK: HUD pictures from the real views

    /// The real HUD in a recording state, cut to the pill and the recording bar.
    static func hud(_ fields: [String: Any], client: String, demo: Bool = false, save: Bool = false) async throws -> CGImage {
        var json: [String: Any] = ["version": 1, "surface": "hud", "size": [600, 130], "session": ["client": client], "notes": demo ? 0 : 1]
        json.merge(fields) { $1 }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-demo-mock.json")
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let state = try UIState(file: file)
        let controller = try await Surfaces.controller(state)
        if demo {
            controller.clientIcon = { _ in
                let image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)!
                image.isTemplate = true
                return image
            }
        }
        let view = HUDView(controller: controller)
            .overlay(alignment: .topLeading) {
                if save {
                    SaveButtonPatch().offset(x: 442, y: 24)
                }
            }
            .frame(width: 600, height: 130)
            .transaction { $0.disablesAnimations = true }
        return try await clearRender(NSHostingView(rootView: view), size: CGSize(width: 600, height: 130))
    }

    static func page(_ title: String, _ subtitle: String, scenes: [Scene], to file: URL) async throws {
        let captionHeight: CGFloat = 34
        let height = 92 + CGFloat(scenes.count) * (sceneSize.height + captionHeight + 18)
        let view = VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 22, weight: .bold))
                Text(subtitle).font(.system(size: 13.5)).foregroundStyle(.secondary)
            }
            .frame(height: 56, alignment: .leading)
            ForEach(Array(scenes.enumerated()), id: \.offset) { _, scene in
                VStack(alignment: .leading, spacing: 8) {
                    Text(scene.caption).font(.system(size: 13, weight: .medium)).frame(height: captionHeight - 8, alignment: .leading)
                    scene.body
                        .frame(width: sceneSize.width, height: sceneSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(18)
        .foregroundStyle(Color(white: 0.1))
        .frame(width: sceneSize.width + 36, height: height, alignment: .topLeading)
        .background(Color(white: 0.96))
        .environment(\.colorScheme, .light)
        .transaction { $0.disablesAnimations = true }
        let image = try await Renderer.render(NSHostingView(rootView: view), size: CGSize(width: sceneSize.width + 36, height: height), appearance: .aqua)
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        try png.write(to: file)
    }

    /// As `Renderer.render`, on a clear background, so the HUD can sit on the mock desktop.
    static func clearRender(_ view: NSView, size: CGSize) async throws -> CGImage {
        _ = Renderer.fixesScrollerStyle
        let window = MockWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        let scale = CGFloat(Renderer.scale)
        let context = Renderer.bitmapContext(width: Int(size.width * scale), height: Int(size.height * scale))!
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        view.layer!.render(in: context)
        window.contentView = nil
        return context.makeImage()!
    }
}

private final class MockWindow: NSWindow {
    override var backingScaleFactor: CGFloat { CGFloat(Renderer.scale) }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

struct Scene {
    let caption: String
    let body: AnyView

    @MainActor
    init(caption: String, @ViewBuilder body: () -> some View) {
        self.caption = caption
        self.body = AnyView(body())
    }
}

// MARK: Scene

enum BubbleShape { case circle, rounded }

/// A desktop with an app window, the real HUD at the top, mock parts under it, and the bubble.
struct SceneBody<Below: View>: View {
    let hud: CGImage
    /// The part of the HUD picture to show: 64 for the pill, 106 for the pill and the bar.
    let hudHeight: CGFloat
    let bubble: BubbleShape?
    var corner: Alignment = .bottomLeading
    var bubbleControls = false
    @ViewBuilder let below: () -> Below

    var body: some View {
        ZStack(alignment: .top) {
            Desktop()
            if let bubble {
                VStack(spacing: 8) {
                    CameraBubble(shape: bubble)
                    if bubbleControls {
                        BubbleControls()
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner)
            }
            VStack(spacing: 0) {
                Image(decorative: hud, scale: CGFloat(Renderer.scale))
                    .frame(width: 600, height: hudHeight, alignment: .top)
                    .clipped()
                below()
                    .environment(\.colorScheme, .dark)
            }
            .frame(width: 600)
            .padding(.top, 0)
        }
    }
}

/// A wallpaper with the app that the demo shows.
struct Desktop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(mockHex: "#3B5BA9"), Color(mockHex: "#8A5FA8"), Color(mockHex: "#D9897A")], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    ForEach(["#FF5F57", "#FEBC2E", "#28C840"], id: \.self) { Circle().fill(Color(mockHex: $0)).frame(width: 11, height: 11) }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Color(white: 0.93))
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(0..<6, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 4).fill(Color(white: index == 1 ? 0.78 : 0.86)).frame(width: index.isMultiple(of: 2) ? 90 : 70, height: 10)
                        }
                        Spacer()
                    }
                    .padding(16)
                    .frame(width: 140)
                    .background(Color(white: 0.96))
                    VStack(alignment: .leading, spacing: 14) {
                        RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.2)).frame(width: 220, height: 18)
                        RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.8)).frame(width: 340, height: 10)
                        HStack(spacing: 12) {
                            ForEach(0..<3, id: \.self) { index in
                                VStack(alignment: .leading, spacing: 8) {
                                    RoundedRectangle(cornerRadius: 6).fill(Color(mockHex: ["#DCE7FF", "#FFE3D6", "#DFF5E3"][index])).frame(height: 70)
                                    RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.8)).frame(width: 80, height: 8)
                                }
                            }
                        }
                        RoundedRectangle(cornerRadius: 8).fill(Color(mockHex: "#2F76FF")).frame(width: 110, height: 28)
                        Spacer()
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
            .frame(width: 620, height: 300)
            .offset(y: 70)
        }
    }
}

/// A stand-in for the camera's picture: a person in a room.
struct CameraBubble: View {
    let shape: BubbleShape
    var side: CGFloat = 132

    var body: some View {
        let clip = shape == .circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 26))
        ZStack {
            LinearGradient(colors: [Color(mockHex: "#E8D5BE"), Color(mockHex: "#8C9AA8")], startPoint: .top, endPoint: .bottom)
            Rectangle().fill(Color(mockHex: "#6F7F5A").opacity(0.5)).frame(width: 30, height: side).offset(x: -side * 0.36)
            Image(systemName: "person.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color(mockHex: "#3A3F4A"))
                .frame(width: side * 0.72)
                .offset(y: side * 0.2)
        }
        .frame(width: side, height: side)
        .clipShape(clip)
        .overlay(clip.stroke(Color.white.opacity(0.9), lineWidth: 3))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
    }
}

// MARK: Mock controls in the HUD's style

/// The real Send button's look, with Save.
struct SaveButtonPatch: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.down").font(.system(size: 10.5, weight: .bold))
            Text("Save")
        }
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 74, height: 28)
        .background(Capsule().fill(Color.tildeBlue))
    }
}

/// A row of a HUD card that turns something on: grey with a check mark while on.
struct ToggleRow: View {
    let symbol: String
    let title: String
    var detail: String?
    let isOn: Bool
    let width: CGFloat

    var body: some View {
        let size = HUDAccessory.size
        HStack(spacing: size.scaled(4)) {
            HUDButtonLabel(image: Image(systemName: symbol), title: title, fillsWidth: true)
            if let detail {
                Text(detail).font(.system(size: size.font(11), weight: .medium)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Image(systemName: "checkmark")
                .font(.system(size: size.font(10.5), weight: .semibold))
                .opacity(isOn ? 1 : 0)
        }
        .modifier(HUDButtonChrome(width: width, isOn: isOn, padding: 10))
    }
}

struct CardDivider: View {
    var body: some View {
        Rectangle().fill(.white.opacity(0.1)).frame(width: 150, height: 1).padding(.vertical, 3).padding(.horizontal, 6)
    }
}

/// The source dropdown with Camera and Microphone after the two ways to choose.
struct DropdownA: View {
    static let width = HUDRecordingBar.sourceWidth

    var body: some View {
        let size = HUDAccessory.size
        VStack(spacing: size.scaled(2)) {
            ToggleRow(symbol: "cursorarrow", title: "Select on screen", isOn: true, width: Self.width)
            HUDButton(image: Image(systemName: "square.grid.2x2"), title: "Use window picker", width: Self.width, help: "") {}
            CardDivider()
            ToggleRow(symbol: "video", title: "Camera", isOn: true, width: Self.width)
            ToggleRow(symbol: "mic", title: "Microphone", isOn: true, width: Self.width)
        }
        .padding(size.scaled(4))
        .hudCard(cornerRadius: size.scaled(12))
        .environment(\.pillSize, size)
        .padding(.leading, 165)
        .frame(width: 600, alignment: .leading)
    }
}

/// The card under the HUD subtitle: where the clip goes, then camera and mic for a demo.
struct DestinationCardB: View {
    static let width: CGFloat = 230

    var body: some View {
        let size = HUDAccessory.size
        VStack(alignment: .leading, spacing: size.scaled(2)) {
            ToggleRow(symbol: "arrow.up", title: "Send to Codex", isOn: false, width: Self.width)
            ToggleRow(symbol: "film", title: "Demo video", detail: "MP4", isOn: true, width: Self.width)
            CardDivider()
            ToggleRow(symbol: "video", title: "Camera", detail: "FaceTime HD", isOn: true, width: Self.width)
            ToggleRow(symbol: "mic", title: "Microphone", detail: "MacBook", isOn: true, width: Self.width)
        }
        .padding(size.scaled(4))
        .hudCard(cornerRadius: size.scaled(12))
        .environment(\.pillSize, size)
        .padding(.leading, 56)
        .frame(width: 600, alignment: .leading)
    }
}

/// On the bubble while the pointer is over it, before recording.
struct BubbleControls: View {
    var body: some View {
        let size = HUDAccessory.size
        HStack(spacing: size.scaled(2)) {
            HUDButton(image: Image(systemName: "mic.fill"), isOn: true, help: "Microphone") {}
            HUDButton(image: Image(systemName: "circle"), help: "Shape") {}
            HUDButton(image: Image(systemName: "arrow.up.left.and.arrow.down.right"), help: "Size") {}
            HUDBarDivider()
            HUDButton(image: Image(systemName: "xmark"), help: "Hide camera") {}
        }
        .pillInsets(size)
        .pill()
        .environment(\.colorScheme, .dark)
    }
}

/// The menu of Send after a clip with the camera.
struct SendMenuC: View {
    var body: some View {
        let size = HUDAccessory.size
        VStack(spacing: size.scaled(2)) {
            ToggleRow(symbol: "arrow.up", title: "Send to Codex", isOn: false, width: 180)
            ToggleRow(symbol: "square.and.arrow.down", title: "Save video", detail: "MP4", isOn: true, width: 180)
        }
        .padding(size.scaled(4))
        .hudCard(cornerRadius: size.scaled(12))
        .environment(\.pillSize, size)
        .padding(.leading, 516 - 196)
        .frame(width: 600, alignment: .leading)
    }
}

/// After Stop or Save: where the file is, with what to do with it.
struct SavedToast: View {
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: PillMetrics.iconGap) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Saved Demo 0:42")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Movies › Tilde")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            HStack(spacing: 4) {
                PillTextButton(title: "Show in Finder", isDestructive: false) {}
                PillTextButton(title: "Copy", isDestructive: false) {}
            }
        }
        .pillInsets(.regular, leading: .text)
        .pill()
    }
}

private extension Color {
    init(mockHex hex: String) {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255)
    }
}
