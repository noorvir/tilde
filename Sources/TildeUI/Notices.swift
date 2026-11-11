import Foundation

/// The short notes in the HUD's subtitle, for a moment. Each fits the pill in full, which the
/// subtitle test checks for the whole list.
enum Notice: String, CaseIterable {
    case windowClosed = "Window closed"
    case recordingFailed = "Recording failed"
    case recordingNotSaved = "Recording not saved"
    case recordingStopped = "Recording stopped"
    case reportNotSaved = "Report not saved"
}

/// Why annotating just paused, for the note below the HUD.
enum PauseNotice: Equatable {
    case escape
    case otherApp
}

/// How the confirmation after Send reads: done, or a copy's images that did not reach a
/// remote machine.
enum SentStatus {
    case done, failed
}

/// What the HUD says for a moment: a notice in its subtitle, the note below it after a pause,
/// and the confirmation after Send. Each has its own time, which a new one starts again.
@MainActor
final class Notices: ObservableObject {
    @Published private(set) var notice: Notice?
    @Published private(set) var pause: PauseNotice?
    /// The confirmation after Send, such as "Sent to Codex".
    @Published private(set) var sentText = ""
    @Published private(set) var sentStatus = SentStatus.done
    /// The confirmation after Send has shown for its time.
    var onSentShown: (_ operation: Int) -> Void = { _ in }

    private let noticeTime = Countdown()
    private let pauseTime = Countdown()
    private let sentTime = Countdown()

    /// Shows a notice for 3 seconds.
    func show(_ notice: Notice) {
        self.notice = notice
        noticeTime.start(3) { [weak self] in
            self?.notice = nil
        }
    }

    /// Shows one pause note at a time, for 10 seconds, when turned on with the hidden
    /// setting `hudPauseToast` (the HUD's yellow pause button shows the pause instead).
    func showPause(_ notice: PauseNotice) {
        guard UserDefaults.standard.bool(forKey: "hudPauseToast") else {
            return
        }
        pause = notice
        startPauseTime()
    }

    /// The pointer on the pause note keeps it; leaving it gives it 10 seconds again.
    func holdPause(_ isHeld: Bool) {
        pauseTime.cancel()
        if !isHeld, pause != nil {
            startPauseTime()
        }
    }

    func clearPause() {
        pauseTime.cancel()
        pause = nil
    }

    private func startPauseTime() {
        pauseTime.start(10) { [weak self] in
            self?.pause = nil
        }
    }

    func showSent(_ text: String, status: SentStatus) {
        sentText = text
        sentStatus = status
    }

    /// Ends the confirmation of the flow's `operation` after `seconds`.
    func endSent(_ operation: Int, after seconds: TimeInterval) {
        sentTime.start(seconds) { [weak self] in
            self?.onSentShown(operation)
        }
    }
}

#if DEBUG
extension Notices {
    func setStateForTesting(notice: Notice?, pause: PauseNotice?, sentText: String) {
        self.notice = notice
        self.pause = pause
        self.sentText = sentText
    }
}
#endif
