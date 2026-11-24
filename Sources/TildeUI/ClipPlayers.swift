import AVFoundation
import Foundation

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
    /// The clip's corner radius, in fractions of its shorter side.
    @Published private(set) var corner = VideoFramer.defaultCorner
    /// The camera's first frame: it shows until the camera's player has a frame of its own,
    /// at once and where the camera started after the clip.
    @Published private(set) var cameraPoster: CGImage?
    @Published private(set) var isPlaying = false
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    /// Playing when the scrubber was taken, to go on after it.
    private var wasPlaying = false
    /// Counts Play and Pause, so a start that waited for loading does nothing once paused.
    private var playCount = 0

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
        if let cameraFile {
            Task {
                cameraPoster = await VideoFramer.firstFrame(of: cameraFile)
            }
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
        corner = await VideoFramer.corner(of: video)
    }

    func toggle() {
        if isPlaying {
            pauseBoth()
        } else {
            playBoth()
        }
    }

    /// Both players start on the same frame of the clip at the same host time, once both are
    /// loaded, on that frame and prerolled. A synchronized start before a player is ready to
    /// play raises an exception.
    private func playBoth() {
        playCount += 1
        let count = playCount
        isPlaying = true
        Task {
            await startBoth(count)
        }
    }

    private func startBoth(_ count: Int) async {
        let players = [screen] + (camera.map { [$0] } ?? [])
        while players.contains(where: { $0.status == .unknown || $0.currentItem?.status == .unknown }) {
            try? await Task.sleep(for: .milliseconds(10))
            guard count == playCount else {
                return
            }
        }
        let ready = players.filter { $0.status == .readyToPlay && $0.currentItem?.status == .readyToPlay }
        let time = screen.currentTime()
        for player in ready {
            _ = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        for player in ready {
            _ = await player.preroll(atRate: 1)
        }
        guard count == playCount, isPlaying else {
            return
        }
        let host = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(value: 1, timescale: 20)
        for player in ready {
            player.setRate(1, time: .invalid, atHostTime: host)
        }
        logOffset(count)
    }

    /// The camera's lead over the clip a second after Play, in milliseconds.
    private func logOffset(_ count: Int) {
        guard let camera else {
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard count == playCount, isPlaying else {
                return
            }
            let offset = (camera.currentTime() - screen.currentTime()).seconds * 1000
            CameraLog.note("preview: camera \(String(format: "%.1f", offset)) ms ahead of the clip")
        }
    }

    private func pauseBoth() {
        playCount += 1
        screen.cancelPendingPrerolls()
        camera?.cancelPendingPrerolls()
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
