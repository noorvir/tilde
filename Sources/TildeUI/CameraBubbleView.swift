import AppKit
import AVFoundation
import SwiftUI

/// The camera in the bubble, round or rounded.
struct CameraBubbleView: View {
    @ObservedObject var bubble: CameraBubble
    let display: CameraDisplay

    var body: some View {
        let clip = bubble.shape == .circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: bubble.side * 0.2))
        ZStack {
            Color.tildeInk
            if bubble.isDenied {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: bubble.side * 0.2))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                CameraPreview(display: display)
                switch bubble.cameraState {
                case .starting:
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                case .failed:
                    VStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 16))
                        Text("Camera did not start")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Click to retry")
                            .font(.system(size: 10.5))
                            .opacity(0.7)
                    }
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.tildeInk)
                case .running:
                    EmptyView()
                }
            }
        }
        .frame(width: bubble.side, height: bubble.side)
        .clipShape(clip)
        .overlay(clip.stroke(Color.white.opacity(0.9), lineWidth: 3))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Camera")
    }
}

private struct CameraPreview: NSViewRepresentable {
    let display: CameraDisplay

    func makeNSView(context: Context) -> PreviewView {
        PreviewView(display: display)
    }

    func updateNSView(_ view: PreviewView, context: Context) {}

    /// The camera's picture, filling the view from its centre, as a mirror.
    final class PreviewView: NSView {
        private let display: CameraDisplay

        init(display: CameraDisplay) {
            self.display = display
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(display.layer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            display.layer.bounds = CGRect(origin: .zero, size: bounds.size)
            display.layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }
    }
}

/// Under the bubble: camera and microphone menus, shape, size, and camera off.
struct CameraBubbleBar: View {
    @ObservedObject var bubble: CameraBubble

    var body: some View {
        let size = HUDAccessory.size
        VStack(alignment: .center, spacing: 8) {
            switch bubble.openMenu {
            case .camera: cameraMenu
            case .microphone: microphoneMenu
            case .size: sizeMenu
            case nil: EmptyView()
            }
            HStack(spacing: size.scaled(2)) {
                menuButton(image: Image(systemName: "video.fill"), menu: .camera, help: "Camera")
                menuButton(image: Image(systemName: bubble.isMicrophoneOn ? "mic.fill" : "mic.slash.fill"), menu: .microphone, help: "Microphone")
                HUDBarDivider()
                HUDButton(image: Image(systemName: bubble.shape == .circle ? "circle" : "app"), help: "Shape") {
                    bubble.toggleShape()
                }
                sizeButton
                HUDBarDivider()
                HUDButton(image: Image(systemName: "xmark"), help: "Turn camera off") {
                    bubble.toggle()
                }
            }
            .pillInsets(size)
            .pill()
        }
        .fixedSize()
        .environment(\.colorScheme, .dark)
    }

    private func menuButton(image: Image, menu: CameraBubble.Menu, help: String) -> some View {
        Button {
            bubble.toggleMenu(menu)
        } label: {
            HUDButtonLabel(image: image, opensBelow: true)
                .modifier(HUDButtonChrome(isActive: bubble.openMenu == menu, padding: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
    }

    private var cameraMenu: some View {
        MenuCard {
            ForEach(bubble.cameras, id: \.uniqueID) { camera in
                MenuRow(symbol: "video", title: camera.localizedName, isOn: camera.uniqueID == bubble.currentCameraID) {
                    bubble.chooseCamera(camera.uniqueID)
                }
            }
        }
    }

    private var microphoneMenu: some View {
        MenuCard {
            MenuRow(symbol: "mic", title: "Record microphone", isOn: bubble.isMicrophoneOn) {
                bubble.toggleMicrophone()
            }
            MenuDivider()
            ForEach(bubble.microphones, id: \.uniqueID) { microphone in
                MenuRow(symbol: "mic", title: microphone.localizedName, isOn: microphone.uniqueID == bubble.currentMicrophoneID) {
                    bubble.chooseMicrophone(microphone.uniqueID)
                }
            }
        }
    }

    /// The current size's icon; grey while its sizes show.
    private var sizeButton: some View {
        let name = CameraBubble.sizes[bubble.sizeIndex].name
        return Button {
            bubble.toggleMenu(.size)
        } label: {
            SizeIcon(shape: bubble.shape, index: bubble.sizeIndex)
                .modifier(HUDButtonChrome(isOn: bubble.openMenu == .size))
        }
        .buttonStyle(.plain)
        .tildeTooltip(bubble.openMenu == .size ? nil : "Size: \(name)")
        .accessibilityLabel("Size")
        .accessibilityValue(name)
    }

    /// A row of the sizes, each drawn as the bubble's shape at that size.
    private var sizeMenu: some View {
        let size = HUDAccessory.size
        return HStack(spacing: size.scaled(2)) {
            ForEach(CameraBubble.sizes.indices, id: \.self) { index in
                let name = CameraBubble.sizes[index].name
                Button {
                    bubble.chooseSize(index)
                } label: {
                    SizeIcon(shape: bubble.shape, index: index)
                        .modifier(HUDButtonChrome(isOn: index == bubble.sizeIndex))
                }
                .buttonStyle(.plain)
                .tildeTooltip(name)
                .accessibilityLabel(name)
                .accessibilityAddTraits(index == bubble.sizeIndex ? .isSelected : [])
            }
        }
        .menuCard()
    }
}

/// The bubble's shape drawn small, medium or large, in a frame of the largest.
private struct SizeIcon: View {
    let shape: CameraBubble.Shape
    let index: Int
    @Environment(\.pillSize) private var pillSize

    var body: some View {
        let side = pillSize.scaled([7, 10, 13][min(index, 2)])
        let frame = pillSize.scaled(14)
        Group {
            if shape == .circle {
                Circle().strokeBorder(lineWidth: 1.5)
            } else {
                RoundedRectangle(cornerRadius: side * 0.28).strokeBorder(lineWidth: 1.5)
            }
        }
        .frame(width: side, height: side)
        .frame(width: frame, height: frame)
    }
}
