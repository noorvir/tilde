import Foundation
import os

/// Save video: writes a clip with its camera on its layout to Downloads, then shows the toast
/// with the file for 10 seconds.
@MainActor
final class SavedVideos: ObservableObject {
    /// The clip whose video is being saved.
    @Published private(set) var saving: URL?
    /// The video file written last, while its toast shows.
    @Published private(set) var saved: URL?
    private let savedTime = Countdown()
    private let notices: Notices
    private let log = Logger(subsystem: "dev.tilde.app", category: "annotate")

    init(notices: Notices) {
        self.notices = notices
    }

    /// Does nothing while another video is being saved.
    func save(_ video: URL, camera: URL?, layout: ClipLayout) {
        guard saving == nil else {
            return
        }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let formatter = DateFormatter()
        // Digits in every locale: the name is for files.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let file = folder.appendingPathComponent("Tilde \(formatter.string(from: Date())).mp4")
        saving = video
        Task { [weak self] in
            guard let self else {
                return
            }
            let spinner = SpinnerTime()
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await VideoFramer.export(video, camera: camera, layout: layout, to: file)
                saved = file
                savedTime.start(10) { [weak self] in
                    self?.saved = nil
                }
            } catch {
                log.error("could not save video: \(String(describing: error), privacy: .public)")
                notices.show(.recordingNotSaved)
            }
            await spinner.waitForMinimum()
            saving = nil
        }
    }
}
