import AVFoundation
import os

/// Puts a clip's camera file on the clip's time. The camera starts recording later than the
/// screen's first frame, after the clip has started; its file begins at its own first frame.
/// Shifted once at Stop, the file plays in step with the clip and its sound in the preview, in
/// the saved video and after a restore.
enum CameraAlignment {
    private static let log = Logger(subsystem: "dev.tilde.app", category: "camera")

    /// How the camera's own time maps to the clip's: `offset` seconds is when the camera's
    /// first frame came after the clip's first frame (negative when before).
    struct Edit: Equatable {
        /// Nothing of the camera shows for this long at the clip's start.
        var emptyAtStart: Double
        /// The camera's first seconds that came before the clip, cut off.
        var trimmedAtStart: Double
    }

    /// Shorter than a frame at 60 frames a second: no edit.
    static func edit(offset: Double) -> Edit? {
        guard abs(offset) >= 1.0 / 60 else {
            return nil
        }
        return offset > 0 ? Edit(emptyAtStart: offset, trimmedAtStart: 0) : Edit(emptyAtStart: 0, trimmedAtStart: -offset)
    }

    /// Rewrites `recording` in place, shifted onto the clip that started at `clipStart`.
    /// Passthrough: no frame is encoded again.
    static func align(_ recording: CameraRecording, toClipStartingAt clipStart: CMTime) async {
        guard let start = recording.start, start.isValid, clipStart.isValid else {
            log.notice("camera start unknown: not aligned")
            return
        }
        let offset = (start - clipStart).seconds
        log.notice("camera started \(offset, format: .fixed(precision: 3), privacy: .public) s after the clip")
        guard let edit = edit(offset: offset) else {
            return
        }
        do {
            try await rewrite(recording.file, with: edit)
        } catch {
            log.error("could not align the camera: \(String(describing: error), privacy: .public)")
        }
    }

    private static func rewrite(_ file: URL, with edit: Edit) async throws {
        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return
        }
        let duration = try await asset.load(.duration)
        let trim = CMTime(seconds: edit.trimmedAtStart, preferredTimescale: 600)
        guard trim < duration else {
            return
        }
        let composition = AVMutableComposition()
        guard let part = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return
        }
        try part.insertTimeRange(CMTimeRange(start: trim, end: duration), of: track, at: .zero)
        if edit.emptyAtStart > 0 {
            part.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: edit.emptyAtStart, preferredTimescale: 600)))
        }
        part.preferredTransform = try await track.load(.preferredTransform)

        let aligned = file.deletingLastPathComponent().appendingPathComponent("aligned-\(UUID().uuidString).mov")
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            return
        }
        session.outputURL = aligned
        session.outputFileType = .mov
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: aligned)
            throw session.error ?? CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(file, withItemAt: aligned)
    }
}
