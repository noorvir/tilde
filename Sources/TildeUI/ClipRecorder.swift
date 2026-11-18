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

    private var recorder: ScreenRecorder?
    /// What the clip in progress shows: its name, such as "Safari window", and its frame.
    private var recorded = (name: "", frame: CGRect.zero)
    /// Clips whose source went away before their start was taken; they end once it is.
    private var endedEarly: Set<URL> = []
    private let log = Logger(subsystem: "dev.tilde.app", category: "recording")

    /// Starts recording `source` into `video` for the flow's start `operation`. `windowName`:
    /// the name of a window's app as the HUD shows it.
    func start(_ source: RecordingSource, windowName: String?, into video: URL, browserWindow: Int?, operation: Int) {
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
        Task {
            do {
                let started = try await ScreenRecorder.start(source, to: video, browserWindow: browserWindow, onSourceEnded: sourceEnded)
                dispatch(.clipStarted(operation), [
                    .adoptClip: { [self] in
                        recorder = started
                        recorded = (name, frame)
                        clock = (Date(), 0)
                        log.notice("recording \(name, privacy: .public)")
                    },
                    .dropClip: { started.discard() },
                ])
                // A source that went away meanwhile ends the clip now that it is taken.
                if endedEarly.remove(video) != nil, recorder?.video == video {
                    dispatch(.captureStopped, [:])
                }
            } catch {
                log.error("could not start recording: \(String(describing: error), privacy: .public)")
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
        clock = (Date(), clock.before + Date().timeIntervalSince(clock.since))
    }

    func resume() {
        recorder?.resume()
        clock = (Date(), clock.before)
    }

    /// Saves the clip in progress for the flow's stop `operation`.
    func finish(operation: Int) {
        guard let recorder else {
            return
        }
        self.recorder = nil
        let recorded = self.recorded
        Task {
            do {
                let clip = try await recorder.stop()
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

    /// Deletes the video of a recording's draft; other drafts have no file.
    nonisolated static func deleteVideo(of draft: Draft) {
        if case .recording(let video, _, _) = draft.annotation.target {
            try? FileManager.default.removeItem(at: video)
        }
    }
}
