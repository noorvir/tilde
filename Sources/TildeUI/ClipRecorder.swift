import AppKit
import os
import TildeCore

/// The clip of recording mode: starts the recorder, keeps the clip's clock and what it
/// records, and turns a stopped clip into a draft. The session's flow decides each step; a
/// result that arrives when the flow no longer waits for it is thrown away.
@MainActor
final class ClipRecorder {
    /// How long the clip in progress has recorded: `before` seconds until `since`, and on
    /// since then while it records. It changes only with the flow's clip, which redraws the HUD.
    var clock = (since: Date(), before: TimeInterval(0))
    /// Hands a result to the session's flow, with what to do for each effect it may return.
    var dispatch: (SessionFlow.Event, [SessionFlow.Effect: () -> Void]) -> Void = { _, _ in }
    /// Puts a stopped clip in the list.
    var keep: (Draft) -> Void = { _ in }
    /// Records the camera beside a clip, while its bubble shows.
    weak var camera: CameraBubble?
    /// The camera file of the clip in progress.
    private var cameraFile: URL?

    private var recorder: ScreenRecorder?
    /// What the clip in progress shows: its name, such as "Safari window", and its frame.
    private var recorded = (name: "", frame: CGRect.zero)
    /// Clips whose source went away before their start was taken; they end once it is.
    private var endedEarly: Set<URL> = []
    private let log = Logger(subsystem: "dev.tilde.app", category: "recording")

    /// Starts recording `source` into `video` for the flow's start `operation`. `windowName`:
    /// the name of a window's app as the HUD shows it. `recordsCamera`: the camera goes into a
    /// file of its own beside the video.
    func start(_ source: RecordingSource, windowName: String?, into video: URL, extras: ScreenRecorder.Extras, recordsCamera: Bool, operation: Int) {
        // What the report says the clip shows.
        let name: String
        let frame: CGRect
        switch source {
        case .window(let window):
            name = "\(windowName ?? window.app) window"
            frame = window.frame
        case .screen(let display):
            name = SourcePickerModel.name(of: display)
            frame = NSScreen.screens.first { $0.displayID == display }?.frame.flipped ?? .zero
        case .phone(let phone):
            name = phone.name
            frame = .zero
        }
        let sourceEnded: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                self?.sourceEnded(video)
            }
        }
        // The camera file takes about a second to start: it starts before the screen does,
        // and Stop cuts off what came before the clip's first frame.
        if recordsCamera, let camera {
            let file = Self.cameraFile(of: video)
            cameraFile = file
            camera.startRecording(to: file)
        }
        Task {
            do {
                let started = try await ScreenRecorder.start(source, to: video, extras: extras, onSourceEnded: sourceEnded)
                dispatch(.clipStarted(operation), [
                    .adoptClip: { [self] in
                        recorder = started
                        recorded = (name, frame)
                        clock = (Date(), 0)
                        log.notice("recording \(name, privacy: .public)")
                    },
                    .dropClip: { [self] in
                        started.discard()
                        dropCameraFile()
                    },
                ])
                // A source that went away meanwhile ends the clip now that it is taken.
                if endedEarly.remove(video) != nil, recorder?.video == video {
                    dispatch(.captureStopped, [:])
                }
            } catch {
                log.error("could not start recording: \(String(describing: error), privacy: .public)")
                dropCameraFile()
                dispatch(.clipStartFailed(operation), [:])
            }
        }
    }

    /// The recorded window moved to `frame`, in Quartz coordinates.
    func follow(windowFrame frame: CGRect) {
        recorder?.follow(windowFrame: frame)
    }

    func pause() {
        recorder?.pause()
        if cameraFile != nil {
            camera?.pauseRecording()
        }
        clock = (Date(), clock.before + Date().timeIntervalSince(clock.since))
    }

    func resume() {
        recorder?.resume()
        if cameraFile != nil {
            camera?.resumeRecording()
        }
        clock = (Date(), clock.before)
    }

    /// Saves the clip in progress for the flow's stop `operation`.
    func finish(operation: Int) {
        guard let recorder else {
            return
        }
        self.recorder = nil
        let recorded = self.recorded
        let recordsCamera = cameraFile != nil
        cameraFile = nil
        Task {
            do {
                let clip = try await recorder.stop()
                // The camera file is finished, also one cut short by the camera going off, and
                // put on the clip's time.
                if recordsCamera, let recording = await camera?.stopRecording() {
                    await CameraAlignment.align(recording, toClipStartingAt: clip.start)
                }
                let target = Target.recording(video: clip.video, seconds: clip.seconds, source: recorded.name)
                let annotation = Annotation(comment: "", target: target, frame: recorded.frame, image: clip.poster, contextImage: nil)
                let captures = Captures(image: clip.poster, contextImage: nil)
                let draft = Draft(annotation: annotation, marker: .zero, chip: "Recording \(clipLength(clip.seconds))", capture: Task { captures })
                dispatch(.clipFinished(operation), [
                    .keepClip: { [self] in keep(draft) },
                    .dropClip: { Self.deleteVideo(of: draft) },
                ])
                log.notice("recorded \(Int(clip.seconds), privacy: .public) s")
            } catch {
                log.error("could not finish recording: \(String(describing: error), privacy: .public)")
                dispatch(.clipFailed(operation), [:])
            }
        }
    }

    /// Throws away the clip in progress.
    func discard() {
        recorder?.discard()
        recorder = nil
        dropCameraFile()
    }

    /// Ends the camera file in progress, if any, and deletes it.
    private func dropCameraFile() {
        guard cameraFile != nil else {
            return
        }
        cameraFile = nil
        Task {
            if let recording = await camera?.stopRecording() {
                try? FileManager.default.removeItem(at: recording.file)
            }
        }
    }

    /// The recorded window, display or phone went away: the clip ends at its last frame. Before
    /// its start is taken, it ends right after.
    private func sourceEnded(_ video: URL) {
        guard recorder?.video == video else {
            endedEarly.insert(video)
            return
        }
        dispatch(.captureStopped, [:])
    }

    /// Deletes the video of a recording's draft, and its camera file; other drafts have no file.
    nonisolated static func deleteVideo(of draft: Draft) {
        if case .recording(let video, _, _) = draft.annotation.target {
            try? FileManager.default.removeItem(at: video)
            try? FileManager.default.removeItem(at: cameraFile(of: video))
        }
    }

    /// Where a clip's camera is recorded, beside its video. It stays on disk with the clip, so a
    /// restored or carried clip has it too.
    nonisolated static func cameraFile(of video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("camera.mov")
    }
}
