import AVFoundation
import SwiftUI

/// A recording in the preview, as its saved video will be: the clip and its camera on a
/// background. Drag either to move it, and its corner dot to resize it. A drag moves the
/// canvas's layers directly and goes to the clip's layout when it ends: no view redraws
/// while it goes on.
struct ClipComposer: View {
    @ObservedObject var controller: AnnotationController
    @ObservedObject private var backgrounds: VideoBackgrounds
    @ObservedObject private var card: PreviewCard
    let video: URL
    @StateObject private var players: ClipPlayers

    init(controller: AnnotationController, video: URL) {
        self.controller = controller
        backgrounds = controller.backgrounds
        card = controller.previewCard
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
                ComposerCanvas(players: players, layout: layout, clipSize: players.clipSize, corner: players.corner, cameraPoster: players.cameraPoster) { changed in
                    controller.setLayout(changed, of: video)
                }
                // A click on the picture closes the open menu, and moves nothing.
                .allowsHitTesting(!card.showsBackgrounds)
            }
            .contentShape(Rectangle())
            .onTapGesture { card.showsBackgrounds = false }
            .aspectRatio(ClipLayout.aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.1)).allowsHitTesting(false))
            .frame(maxWidth: .infinity)

            controls(layout)
        }
        .onDisappear { players.stop() }
    }

    /// One line from the left: the background and its menu, the camera's shape, then Play
    /// and the scrubber over the rest.
    private func controls(_ layout: ClipLayout) -> some View {
        HStack(spacing: 6) {
            backgroundButton(layout.background)
            if layout.cameraCenter != nil {
                HUDButton(image: Image(systemName: layout.cameraShape == .circle ? "circle" : "app"), help: "Camera shape") {
                    var changed = controller.layout(of: video)
                    changed.cameraShape = changed.cameraShape == .circle ? .rounded : .circle
                    controller.setLayout(changed, of: video)
                }
            }
            HUDBarDivider()
            HUDButton(image: Image(systemName: players.isPlaying ? "pause.fill" : "play.fill"), help: players.isPlaying ? "Pause" : "Play") {
                players.toggle()
            }
            ClipScrubber(players: players, clock: players.clock)
        }
        .environment(\.colorScheme, .dark)
    }

    /// The current background; its menu opens upward, over the picture.
    private func backgroundButton(_ current: VideoBackground) -> some View {
        Button {
            card.showsBackgrounds.toggle()
        } label: {
            HUDButtonLabel(image: Image(nsImage: BackgroundSwatch.image(of: current)), opensBelow: true)
                .modifier(HUDButtonChrome(isActive: card.showsBackgrounds, padding: 6))
        }
        .buttonStyle(.plain)
        .tildeTooltip(card.showsBackgrounds ? nil : "Background")
        .accessibilityLabel("Background")
        .accessibilityValue(title(of: current))
        // A line at the button's top edge, which the menu stands on: it opens upward.
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(height: 0)
                .overlay(alignment: .bottomLeading) {
                    if card.showsBackgrounds {
                        backgroundMenu(current)
                            .fixedSize()
                            .padding(.bottom, 8)
                    }
                }
        }
    }

    private func backgroundMenu(_ current: VideoBackground) -> some View {
        let all = VideoGradient.allCases.map(VideoBackground.gradient) + backgrounds.images.map(VideoBackground.image)
        return MenuCard {
            ForEach(all, id: \.key) { background in
                MenuRow(image: Image(nsImage: BackgroundSwatch.image(of: background)), title: title(of: background), isOn: background == current) {
                    choose(background)
                }
                .contextMenu {
                    if case .image(let url) = background {
                        Button("Remove") { backgrounds.remove(url) }
                    }
                }
            }
            MenuDivider()
            MenuRow(symbol: "plus", title: "Add image") {
                card.showsBackgrounds = false
                if let added = backgrounds.add() {
                    choose(.image(added))
                }
            }
        }
    }

    private func title(of background: VideoBackground) -> String {
        switch background {
        case .gradient(let gradient):
            return gradient.name
        case .image(let url):
            let index = backgrounds.images.firstIndex(of: url) ?? 0
            return "Image \(index + 1)"
        }
    }

    private func choose(_ background: VideoBackground) {
        card.showsBackgrounds = false
        var layout = controller.layout(of: video)
        layout.background = background
        controller.setLayout(layout, of: video)
    }
}

/// A background drawn small, for its button and its row in the menu.
@MainActor
private enum BackgroundSwatch {
    private static let size = CGSize(width: 24, height: 16)
    private static let images = NSCache<NSString, NSImage>()

    static func image(of background: VideoBackground) -> NSImage {
        if let image = images.object(forKey: background.key as NSString) {
            return image
        }
        let source: NSImage? = switch background {
        case .gradient(let gradient):
            VideoFramer.gradientImage(gradient, size: CGSize(width: size.width * 2, height: size.height * 2)).map { NSImage(cgImage: $0, size: size) }
        case .image(let url):
            NSImage(contentsOf: url)
        }
        let image = NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
            NSColor.gray.setFill()
            rect.fill()
            if let source {
                // Fills the swatch from the centre.
                let scale = max(rect.width / source.size.width, rect.height / source.size.height)
                let drawn = CGSize(width: source.size.width * scale, height: source.size.height * scale)
                source.draw(in: CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
            }
            return true
        }
        images.setObject(image, forKey: background.key as NSString)
        return image
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
            .frame(minWidth: 120, maxWidth: .infinity)
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
