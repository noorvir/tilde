import AVFoundation
import SwiftUI

/// A recording in the preview, as its saved video will be: the clip and its camera on a
/// background. Drag either to move it, and its corner dot to resize it. A drag moves the
/// canvas's layers directly and goes to the clip's layout when it ends: no view redraws
/// while it goes on.
struct ClipComposer: View {
    @ObservedObject var controller: AnnotationController
    @ObservedObject private var backgrounds: VideoBackgrounds
    let video: URL
    @StateObject private var players: ClipPlayers

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
        let layout = controller.layout(of: video)
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                BackgroundFill(background: layout.background)
                ComposerCanvas(players: players, layout: layout, clipSize: players.clipSize) { changed in
                    controller.setLayout(changed, of: video)
                }
            }
            .aspectRatio(ClipLayout.aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.1)).allowsHitTesting(false))
            .frame(maxWidth: .infinity)

            controls(layout)
        }
        .onDisappear { players.stop() }
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

/// The clip and its camera as layers on the composer's background. The view owns a drag from
/// its first tick to its end; the layout it shows changes only between drags.
struct ComposerCanvas: NSViewRepresentable {
    let players: ClipPlayers
    let layout: ClipLayout
    let clipSize: CGSize
    /// Called once at the end of a drag that moved or resized something.
    let onChange: (ClipLayout) -> Void

    func makeNSView(context: Context) -> CanvasView {
        CanvasView(screen: players.screen, camera: players.camera)
    }

    func updateNSView(_ view: CanvasView, context: Context) {
        view.onChange = onChange
        view.show(layout, clipSize: clipSize)
    }

    final class CanvasView: NSView {
        enum Part {
            case screen, camera
        }

        private struct Drag {
            let part: Part
            let resizes: Bool
            let start: NSPoint
            let layout: ClipLayout
            var hasMoved = false
        }

        var onChange: (ClipLayout) -> Void = { _ in }
        private(set) var shown = ClipLayout(background: .gradient(.dusk))
        private var clipSize = CGSize(width: 16, height: 10)
        private var drag: Drag?
        private let screen: PartLayers
        private let camera: PartLayers?

        init(screen: AVPlayer, camera: AVPlayer?) {
            self.screen = PartLayers(player: screen, fills: false, mirrored: false)
            self.camera = camera.map { PartLayers(player: $0, fills: true, mirrored: true) }
            super.init(frame: .zero)
            wantsLayer = true
            self.screen.add(to: layer)
            self.camera?.add(to: layer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override var isFlipped: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// Ignored while a drag goes on: the drag's own layout shows until it ends.
        func show(_ layout: ClipLayout, clipSize: CGSize) {
            guard drag == nil, layout != shown || clipSize != self.clipSize else {
                return
            }
            shown = layout
            self.clipSize = clipSize
            place()
        }

        override func layout() {
            super.layout()
            place()
        }

        private func place() {
            let frames = shown.frames(in: bounds.size, clip: clipSize)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            screen.place(in: frames.screen, radius: min(frames.screen.width, frames.screen.height) * 0.025, rim: 0)
            if let camera {
                if let frame = frames.camera {
                    let radius = shown.cameraShape == .circle ? frame.width / 2 : frame.width * 0.2
                    camera.place(in: frame, radius: radius, rim: max(1.5, frame.width * 0.012))
                }
                camera.isHidden = frames.camera == nil
            }
            CATransaction.commit()
        }

        // MARK: Dragging

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard let (part, resizes) = target(at: point) else {
                super.mouseDown(with: event)
                return
            }
            drag = Drag(part: part, resizes: resizes, start: point, layout: shown)
        }

        override func mouseDragged(with event: NSEvent) {
            guard var drag else {
                return
            }
            let point = convert(event.locationInWindow, from: nil)
            let translation = CGSize(width: point.x - drag.start.x, height: point.y - drag.start.y)
            if !drag.hasMoved {
                guard hypot(translation.width, translation.height) >= (drag.resizes ? 1 : 2) else {
                    return
                }
                drag.hasMoved = true
                self.drag = drag
            }
            shown = dragged(drag, by: translation)
            place()
        }

        override func mouseUp(with event: NSEvent) {
            guard let drag else {
                return
            }
            self.drag = nil
            if drag.hasMoved, shown != drag.layout {
                onChange(shown)
            }
        }

        /// The part under `point`, top first; `resizes` on its corner dot.
        private func target(at point: NSPoint) -> (Part, resizes: Bool)? {
            let frames = shown.frames(in: bounds.size, clip: clipSize)
            if camera != nil, let frame = frames.camera {
                if PartLayers.dotArea(of: frame).contains(point) {
                    return (.camera, true)
                }
                if shown.cameraShape == .circle {
                    if hypot(point.x - frame.midX, point.y - frame.midY) <= frame.width / 2 {
                        return (.camera, false)
                    }
                } else if frame.contains(point) {
                    return (.camera, false)
                }
            }
            if PartLayers.dotArea(of: frames.screen).contains(point) {
                return (.screen, true)
            }
            if frames.screen.contains(point) {
                return (.screen, false)
            }
            return nil
        }

        /// A move keeps the part's centre on the canvas; a resize moves the bottom-right corner
        /// with the pointer, and the part keeps its centre and its shape.
        private func dragged(_ drag: Drag, by translation: CGSize) -> ClipLayout {
            let canvas = bounds.size
            let start = drag.layout
            var layout = start
            if drag.resizes {
                let frames = start.frames(in: canvas, clip: clipSize)
                switch drag.part {
                case .screen:
                    let width = frames.screen.width + 2 * translation.width
                    layout.screenScale = min(max(start.screenScale * width / max(frames.screen.width, 1), 0.2), 1)
                case .camera:
                    let side = start.cameraSide * canvas.height + translation.width + translation.height
                    layout.cameraSide = min(max(side / canvas.height, 0.1), 0.7)
                }
                return layout
            }
            let dx = translation.width / canvas.width
            let dy = translation.height / canvas.height
            switch drag.part {
            case .screen:
                layout.screenCenter = clamped(CGPoint(x: start.screenCenter.x + dx, y: start.screenCenter.y + dy))
            case .camera:
                if let center = start.cameraCenter {
                    layout.cameraCenter = clamped(CGPoint(x: center.x + dx, y: center.y + dy))
                }
            }
            return layout
        }

        private func clamped(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        }

        // MARK: Accessibility

        override func isAccessibilityElement() -> Bool { false }

        override func accessibilityChildren() -> [Any]? {
            let frames = shown.frames(in: bounds.size, clip: clipSize)
            var parts = [("Screen recording", frames.screen), ("Resize screen recording", PartLayers.dotArea(of: frames.screen))]
            if camera != nil, let frame = frames.camera {
                parts += [("Camera", frame), ("Resize camera", PartLayers.dotArea(of: frame))]
            }
            return parts.map { label, frame in
                let element = NSAccessibilityElement()
                element.setAccessibilityRole(.image)
                element.setAccessibilityLabel(label)
                element.setAccessibilityParent(self)
                element.setAccessibilityFrameInParentSpace(frame)
                return element
            }
        }
    }

    /// One part's layers: a shadow drawn from its outline alone, its player clipped to its
    /// shape with an optional white rim, and its corner dot. A path shadow costs no pass over
    /// the video's pixels as the part moves.
    final class PartLayers {
        private static let dot: CGFloat = 12
        private static let dotInset: CGFloat = 4

        private let shadow = CALayer()
        private let clip = CALayer()
        private let player: AVPlayerLayer
        private let dot = CALayer()
        private let mirrored: Bool

        init(player: AVPlayer, fills: Bool, mirrored: Bool) {
            self.player = AVPlayerLayer(player: player)
            self.mirrored = mirrored
            self.player.videoGravity = fills ? .resizeAspectFill : .resizeAspect
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowOpacity = 0.4
            shadow.shadowRadius = mirrored ? 8 : 10
            shadow.shadowOffset = CGSize(width: 0, height: mirrored ? 4 : 5)
            clip.masksToBounds = true
            clip.cornerCurve = .continuous
            clip.borderColor = NSColor.white.cgColor
            clip.addSublayer(self.player)
            dot.backgroundColor = NSColor.white.cgColor
            dot.cornerRadius = Self.dot / 2
            dot.shadowColor = NSColor.black.cgColor
            dot.shadowOpacity = 0.4
            dot.shadowRadius = 2
            dot.shadowOffset = .zero
            dot.shadowPath = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: Self.dot, height: Self.dot), transform: nil)
        }

        /// Where a press takes the corner dot: a little larger than the dot.
        static func dotArea(of frame: CGRect) -> CGRect {
            let side = dot + 2 * dotInset
            return CGRect(x: frame.maxX - side, y: frame.maxY - side, width: side, height: side)
        }

        var isHidden: Bool {
            get { clip.isHidden }
            set {
                shadow.isHidden = newValue
                clip.isHidden = newValue
                dot.isHidden = newValue
            }
        }

        func add(to parent: CALayer?) {
            parent?.addSublayer(shadow)
            parent?.addSublayer(clip)
            parent?.addSublayer(dot)
        }

        /// Call inside a transaction with actions off.
        func place(in frame: CGRect, radius: CGFloat, rim: CGFloat) {
            let local = CGRect(origin: .zero, size: frame.size)
            shadow.frame = frame
            shadow.shadowPath = CGPath(roundedRect: local, cornerWidth: radius, cornerHeight: radius, transform: nil)
            clip.frame = frame
            clip.cornerRadius = radius
            clip.borderWidth = rim
            player.bounds = local
            player.position = CGPoint(x: local.midX, y: local.midY)
            player.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
            let area = Self.dotArea(of: frame)
            dot.frame = area.insetBy(dx: Self.dotInset, dy: Self.dotInset)
        }
    }
}
