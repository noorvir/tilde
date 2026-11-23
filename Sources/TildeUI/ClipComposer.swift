import AVFoundation
import SwiftUI

/// A recording in the preview, as its saved video will be: the clip and its camera on a
/// background. Drag either to move it, and its corner dot to resize it. A drag goes to the
/// clip's layout when it ends; until then only the composer redraws.
struct ClipComposer: View {
    private enum Part {
        case screen, camera
    }

    @ObservedObject var controller: AnnotationController
    @ObservedObject private var backgrounds: VideoBackgrounds
    let video: URL
    @StateObject private var players: ClipPlayers
    @StateObject private var drag = ComposerDrag()

    init(controller: AnnotationController, video: URL) {
        self.controller = controller
        backgrounds = controller.backgrounds
        self.video = video
        // The note's length until the file says its own.
        let seconds = controller.drafts.lazy.compactMap { draft -> Double? in
            guard case .recording(let clip, let seconds, _) = draft.annotation.target, clip == video else {
                return nil
            }
            return seconds
        }.first
        _players = StateObject(wrappedValue: ClipPlayers(video: video, camera: controller.cameraTrack(of: video), seconds: seconds ?? 0))
    }

    var body: some View {
        let layout = drag.layout ?? controller.layout(of: video)
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
                drag.move(to: layout)
            }
            .onEnded { _ in endDrag() }
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
                drag.move(to: layout)
            }
            .onEnded { _ in endDrag() }
    }

    private func beginDrag() -> ClipLayout {
        drag.begin(from: controller.layout(of: video))
    }

    private func endDrag() {
        if let layout = drag.end() {
            controller.setLayout(layout, of: video)
        }
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }

    private func controls(_ layout: ClipLayout) -> some View {
        HStack(spacing: 6) {
            CardButton(symbol: players.isPlaying ? "pause.fill" : "play.fill", help: players.isPlaying ? "Pause" : "Play") {
                players.toggle()
            }
            ClipScrubber(players: players, clock: players.clock)
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

/// A drag in the composer. The layout follows the pointer here and goes to the controller
/// once, at the end: the controller's change redraws the HUD and the preview, and saves.
@MainActor
final class ComposerDrag: ObservableObject {
    /// The layout while a drag goes on.
    @Published private(set) var layout: ClipLayout?
    private var start: ClipLayout?

    /// The layout the drag started from: `current` at its first tick.
    func begin(from current: ClipLayout) -> ClipLayout {
        if let start {
            return start
        }
        start = current
        return current
    }

    func move(to layout: ClipLayout) {
        self.layout = layout
    }

    /// The layout to keep, if the drag moved anything.
    func end() -> ClipLayout? {
        defer {
            layout = nil
            start = nil
        }
        return layout
    }
}

/// A background as the saved video shows it: a gradient, or an image that fills.
private struct BackgroundFill: View {
    let background: VideoBackground
    /// Decoded once: the body runs on every tick of a drag.
    @MainActor private static let images = NSCache<NSURL, NSImage>()

    @MainActor private static func image(at url: URL) -> NSImage? {
        if let image = images.object(forKey: url as NSURL) {
            return image
        }
        let image = NSImage(contentsOf: url)
        if let image {
            images.setObject(image, forKey: url as NSURL)
        }
        return image
    }

    var body: some View {
        switch background {
        case .gradient(let gradient):
            LinearGradient(colors: gradient.cgColors.map { Color(cgColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
        case .image(let url):
            if let image = Self.image(at: url) {
                Color.clear.overlay(Image(nsImage: image).resizable().scaledToFill()).clipped()
            } else {
                Color.gray
            }
        }
    }
}

/// The clip and its camera, which play, pause, seek and start over together, at the same
/// host time. Only the clip has sound.
@MainActor
final class ClipPlayers: ObservableObject {
    let screen: AVPlayer
    let camera: AVPlayer?
    /// Where the clip is, for the scrubber alone: its ticks redraw nothing else.
    let clock = ClipClock()
    /// The clip's size in pixels, once known.
    @Published private(set) var clipSize = CGSize(width: 16, height: 10)
    @Published private(set) var isPlaying = false
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    /// Playing when the scrubber was taken, to go on after it.
    private var wasPlaying = false

    init(video: URL, camera cameraFile: URL?, seconds: Double) {
        clock.duration = seconds
        screen = AVPlayer(url: video)
        camera = cameraFile.map { AVPlayer(url: $0) }
        camera?.isMuted = true
        // Both start at a host time of their own choosing, never on their own.
        screen.automaticallyWaitsToMinimizeStalling = false
        camera?.automaticallyWaitsToMinimizeStalling = false
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: screen.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.ended()
            }
        }
        timeObserver = screen.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.clock.played(to: time.seconds)
            }
        }
        Task {
            await load(video)
        }
    }

    private func load(_ video: URL) async {
        let asset = AVURLAsset(url: video)
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            clock.duration = duration.seconds
        }
        let tracks = try? await asset.loadTracks(withMediaType: .video)
        guard let track = tracks?.first, let size = try? await track.load(.naturalSize), size.width > 0, size.height > 0 else {
            return
        }
        clipSize = size
    }

    func toggle() {
        if isPlaying {
            pauseBoth()
        } else {
            playBoth()
        }
    }

    /// Both players start on the same frame of the clip at the same host time, a moment from now.
    private func playBoth() {
        let time = screen.currentTime()
        let host = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(value: 1, timescale: 20)
        screen.setRate(1, time: time, atHostTime: host)
        camera?.setRate(1, time: time, atHostTime: host)
        isPlaying = true
    }

    private func pauseBoth() {
        screen.pause()
        camera?.pause()
        // The camera stops where the clip does.
        camera?.seek(to: screen.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        isPlaying = false
    }

    /// The scrubber is taken: playing waits until it is let go.
    func beginScrubbing() {
        wasPlaying = isPlaying
        if isPlaying {
            pauseBoth()
        }
        clock.isScrubbing = true
    }

    func scrub(to seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        screen.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        camera?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        clock.position = seconds
    }

    func endScrubbing() {
        clock.isScrubbing = false
        if wasPlaying {
            playBoth()
        }
    }

    func stop() {
        screen.pause()
        camera?.pause()
        isPlaying = false
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        if let timeObserver {
            screen.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    private func ended() {
        isPlaying = false
        screen.seek(to: .zero)
        camera?.pause()
        camera?.seek(to: .zero)
        clock.position = 0
    }
}

/// Where a clip is and how long it is.
@MainActor
final class ClipClock: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
    /// The scrubber is held: the player's ticks do not move it.
    var isScrubbing = false

    func played(to seconds: Double) {
        guard !isScrubbing, seconds.isFinite else {
            return
        }
        position = seconds
    }

    /// "0:03 / 0:09".
    var text: String {
        "\(Self.time(position)) / \(Self.time(duration))"
    }

    static func time(_ seconds: Double) -> String {
        let whole = Int(max(seconds, 0).rounded(.down))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}

/// The seek bar with the time played and the clip's length.
private struct ClipScrubber: View {
    let players: ClipPlayers
    @ObservedObject var clock: ClipClock

    var body: some View {
        HStack(spacing: 8) {
            Slider(
                value: Binding(get: { clock.position }, set: { players.scrub(to: $0) }),
                in: 0...max(clock.duration, 0.1)
            ) { isEditing in
                if isEditing {
                    players.beginScrubbing()
                } else {
                    players.endScrubbing()
                }
            }
            .controlSize(.small)
            .tint(.white)
            .frame(minWidth: 120, maxWidth: 260)
            .accessibilityLabel("Position")
            .accessibilityValue(clock.text)
            Text(clock.text)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize()
                .accessibilityHidden(true)
        }
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
