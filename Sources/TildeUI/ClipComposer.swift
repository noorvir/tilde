import AVFoundation
import SwiftUI

/// A recording in the preview, as its saved video will be: the clip and its camera on a
/// background. Drag either to move it, and its corner dot to resize it. Every change goes to
/// the clip's layout at once.
struct ClipComposer: View {
    private enum Part {
        case screen, camera
    }

    @ObservedObject var controller: AnnotationController
    @ObservedObject private var backgrounds: VideoBackgrounds
    let video: URL
    @StateObject private var players: ClipPlayers
    /// The layout when the drag in progress began.
    @State private var dragStart: ClipLayout?

    init(controller: AnnotationController, video: URL) {
        self.controller = controller
        backgrounds = controller.backgrounds
        self.video = video
        _players = StateObject(wrappedValue: ClipPlayers(video: video, camera: controller.cameraTrack(of: video)))
    }

    var body: some View {
        let layout = controller.layout(of: video)
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                let canvas = geometry.size
                let frames = layout.frames(in: canvas, clip: players.clipSize)
                ZStack(alignment: .topLeading) {
                    BackgroundFill(background: layout.background)
                    screen(frames.screen, canvas: canvas)
                    if let cameraFrame = frames.camera, let camera = players.camera {
                        cameraView(camera, frame: cameraFrame, shape: layout.cameraShape, canvas: canvas)
                    }
                }
                .frame(width: canvas.width, height: canvas.height)
                .clipped()
            }
            .aspectRatio(ClipLayout.aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.1)).allowsHitTesting(false))
            .frame(maxWidth: .infinity)

            controls(layout)
        }
        .onDisappear { players.stop() }
    }

    private func screen(_ frame: CGRect, canvas: CGSize) -> some View {
        let radius = min(frame.width, frame.height) * 0.025
        return PlayerLayerView(player: players.screen, fills: false, mirrored: false)
            .frame(width: frame.width, height: frame.height)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
            .overlay(alignment: .bottomTrailing) { resizeDot(.screen, canvas: canvas) }
            .contentShape(Rectangle())
            .gesture(move(.screen, canvas: canvas))
            .position(x: frame.midX, y: frame.midY)
            .accessibilityLabel("Screen recording")
    }

    private func cameraView(_ player: AVPlayer, frame: CGRect, shape: CameraBubble.Shape, canvas: CGSize) -> some View {
        let clip = shape == .circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: frame.width * 0.2))
        return PlayerLayerView(player: player, fills: true, mirrored: true)
            .frame(width: frame.width, height: frame.height)
            .clipShape(clip)
            .overlay(clip.stroke(Color.white, lineWidth: max(1.5, frame.width * 0.012)))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
            .overlay(alignment: .bottomTrailing) { resizeDot(.camera, canvas: canvas) }
            .contentShape(clip)
            .gesture(move(.camera, canvas: canvas))
            .position(x: frame.midX, y: frame.midY)
            .accessibilityLabel("Camera")
    }

    private func resizeDot(_ part: Part, canvas: CGSize) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .shadow(color: .black.opacity(0.4), radius: 2)
            .padding(4)
            .contentShape(Rectangle())
            .gesture(resize(part, canvas: canvas))
            .accessibilityLabel(part == .screen ? "Resize screen recording" : "Resize camera")
    }

    private func move(_ part: Part, canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = beginDrag()
                let dx = value.translation.width / canvas.width
                let dy = value.translation.height / canvas.height
                var layout = start
                switch part {
                case .screen:
                    layout.screenCenter = clamped(CGPoint(x: start.screenCenter.x + dx, y: start.screenCenter.y + dy))
                case .camera:
                    if let center = start.cameraCenter {
                        layout.cameraCenter = clamped(CGPoint(x: center.x + dx, y: center.y + dy))
                    }
                }
                controller.setLayout(layout, of: video)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// The bottom-right corner follows the pointer; the part keeps its centre and its shape.
    private func resize(_ part: Part, canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = beginDrag()
                let frames = start.frames(in: canvas, clip: players.clipSize)
                var layout = start
                switch part {
                case .screen:
                    let width = frames.screen.width + 2 * value.translation.width
                    layout.screenScale = min(max(start.screenScale * width / max(frames.screen.width, 1), 0.2), 1)
                case .camera:
                    let side = start.cameraSide * canvas.height + value.translation.width + value.translation.height
                    layout.cameraSide = min(max(side / canvas.height, 0.1), 0.7)
                }
                controller.setLayout(layout, of: video)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func beginDrag() -> ClipLayout {
        if let dragStart {
            return dragStart
        }
        let start = controller.layout(of: video)
        dragStart = start
        return start
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }

    private func controls(_ layout: ClipLayout) -> some View {
        HStack(spacing: 6) {
            CardButton(symbol: players.isPlaying ? "pause.fill" : "play.fill", help: players.isPlaying ? "Pause" : "Play") {
                players.toggle()
            }
            Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 18).padding(.horizontal, 4)
            ForEach(VideoGradient.allCases, id: \.self) { gradient in
                swatch(.gradient(gradient), title: gradient.name, selected: layout.background)
            }
            ForEach(Array(backgrounds.images.enumerated()), id: \.element) { index, url in
                swatch(.image(url), title: "Image \(index + 1)", selected: layout.background)
                    .contextMenu {
                        Button("Remove") { backgrounds.remove(url) }
                    }
            }
            CardButton(symbol: "plus", help: "Add a background image") {
                if let added = backgrounds.add() {
                    choose(.image(added))
                }
            }
            Spacer(minLength: 0)
            if layout.cameraCenter != nil {
                CardButton(symbol: layout.cameraShape == .circle ? "circle" : "app", help: "Camera shape") {
                    var changed = controller.layout(of: video)
                    changed.cameraShape = changed.cameraShape == .circle ? .rounded : .circle
                    controller.setLayout(changed, of: video)
                }
            }
        }
    }

    private func swatch(_ background: VideoBackground, title: String, selected: VideoBackground) -> some View {
        let isOn = background == selected
        return Button {
            choose(background)
        } label: {
            BackgroundFill(background: background)
                .frame(width: 30, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isOn ? Color.white : Color.white.opacity(0.2), lineWidth: isOn ? 2 : 1))
        }
        .buttonStyle(.plain)
        .tildeTooltip(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func choose(_ background: VideoBackground) {
        var layout = controller.layout(of: video)
        layout.background = background
        controller.setLayout(layout, of: video)
    }
}

/// A background as the saved video shows it: a gradient, or an image that fills.
private struct BackgroundFill: View {
    let background: VideoBackground

    var body: some View {
        switch background {
        case .gradient(let gradient):
            LinearGradient(colors: gradient.cgColors.map { Color(cgColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
        case .image(let url):
            if let image = NSImage(contentsOf: url) {
                Color.clear.overlay(Image(nsImage: image).resizable().scaledToFill()).clipped()
            } else {
                Color.gray
            }
        }
    }
}

/// The clip and its camera, which play, pause and start over together. Only the clip has sound.
@MainActor
private final class ClipPlayers: ObservableObject {
    let screen: AVPlayer
    let camera: AVPlayer?
    /// The clip's size in pixels, once known.
    @Published private(set) var clipSize = CGSize(width: 16, height: 10)
    @Published private(set) var isPlaying = false
    private var endObserver: NSObjectProtocol?

    init(video: URL, camera cameraFile: URL?) {
        screen = AVPlayer(url: video)
        camera = cameraFile.map { AVPlayer(url: $0) }
        camera?.isMuted = true
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: screen.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.ended()
            }
        }
        Task {
            await loadSize(of: video)
        }
    }

    private func loadSize(of video: URL) async {
        let tracks = try? await AVURLAsset(url: video).loadTracks(withMediaType: .video)
        guard let track = tracks?.first, let size = try? await track.load(.naturalSize), size.width > 0, size.height > 0 else {
            return
        }
        clipSize = size
    }

    func toggle() {
        if isPlaying {
            screen.pause()
            camera?.pause()
        } else {
            screen.play()
            camera?.play()
        }
        isPlaying.toggle()
    }

    func stop() {
        screen.pause()
        camera?.pause()
        isPlaying = false
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    private func ended() {
        isPlaying = false
        screen.seek(to: .zero)
        camera?.pause()
        camera?.seek(to: .zero)
    }
}

/// A player's picture with no controls: fitted, or filling from the centre, and mirrored for
/// the camera.
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    let fills: Bool
    let mirrored: Bool

    func makeNSView(context: Context) -> LayerView {
        LayerView(player: player, fills: fills, mirrored: mirrored)
    }

    func updateNSView(_ view: LayerView, context: Context) {}

    final class LayerView: NSView {
        private let playerLayer: AVPlayerLayer
        private let mirrored: Bool

        init(player: AVPlayer, fills: Bool, mirrored: Bool) {
            playerLayer = AVPlayerLayer(player: player)
            self.mirrored = mirrored
            super.init(frame: .zero)
            wantsLayer = true
            playerLayer.videoGravity = fills ? .resizeAspectFill : .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
            playerLayer.bounds = CGRect(origin: .zero, size: bounds.size)
            playerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }
    }
}
