import Foundation
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
    /// Hands a result to the session's flow, runs its effects and returns them.
    var dispatch: (SessionFlow.Event) -> [SessionFlow.Effect] = { _ in [] }

    private var recorder: ScreenRecorder?
    /// What the clip in progress shows: its name, such as "Safari window", and its frame.
    private var recorded = (name: "", frame: CGRect.zero)
    /// A recorder or a stopped clip that has just arrived, while the flow decides on it.
    private var arrived: Arrived?
    private enum Arrived {
        case recorder(ScreenRecorder)
        case clip(Draft)
    }
    private let log = Logger(subsystem: "dev.tilde.app", category: "recording")

    /// Starts recording `source` into `video` for the flow's start `operation`. `name` and
    /// `frame` say in the report what it shows.
    func start(_ source: RecordingSource, name: String, frame: CGRect, into video: URL, browserWindow: Int?, operation: Int) {
        let sourceEnded: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                self?.sourceEnded(video)
            }
        }
        Task {
            do {
                let started = try await ScreenRecorder.start(source, to: video, browserWindow: browserWindow, onSourceEnded: sourceEnded)
                arrived = .recorder(started)
                defer { arrived = nil }
                guard !dispatch(.clipStarted(operation)).contains(.dropClip) else {
                    return
                }
                recorder = started
                recorded = (name, frame)
                clock = (Date(), 0)
                log.notice("recording \(name, privacy: .public)")
            } catch {
                log.error("could not start recording: \(String(describing: error), privacy: .public)")
                _ = dispatch(.clipStartFailed(operation))
            }
        }
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
                arrived = .clip(Draft(annotation: annotation, marker: .zero, chip: "Recording \(clipLength(clip.seconds))", capture: Task { captures }))
                defer { arrived = nil }
                _ = dispatch(.clipFinished(operation))
                log.notice("recorded \(Int(clip.seconds), privacy: .public) s")
            } catch {
                log.error("could not finish recording: \(String(describing: error), privacy: .public)")
                _ = dispatch(.clipFailed(operation))
            }
        }
    }

    /// Throws away the clip in progress.
    func discard() {
        recorder?.discard()
        recorder = nil
    }

    /// The stopped clip that just arrived, for the flow's `keepClip`.
    var arrivedDraft: Draft? {
        if case .clip(let draft) = arrived {
            return draft
        }
        return nil
    }

    /// Throws away what just arrived, for the flow's `dropClip`.
    func dropArrived() {
        switch arrived {
        case .recorder(let recorder): recorder.discard()
        case .clip(let draft): Self.deleteVideo(of: draft)
        case nil: break
        }
    }

    /// The recorded window, display or phone went away: the clip ends at its last frame.
    private func sourceEnded(_ video: URL) {
        guard recorder?.video == video else {
            return
        }
        _ = dispatch(.captureStopped)
    }

    /// Deletes the video of a recording's draft; other drafts have no file.
    nonisolated static func deleteVideo(of draft: Draft) {
        if case .recording(let video, _, _) = draft.annotation.target {
            try? FileManager.default.removeItem(at: video)
        }
    }
}
