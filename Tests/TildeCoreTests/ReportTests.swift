@testable import TildeCore
import Foundation
import Testing

struct ReportTests {
    /// A recording's length reads the same as in the HUD, the list and the preview.
    @Test func aRecordingSaysItsLengthAsMinutesAndSeconds() {
        #expect(clipLength(9.6) == "0:10")
        #expect(clipLength(65) == "1:05")
        #expect(clipLength(3599.4) == "59:59")

        let video = URL(fileURLWithPath: "/tmp/clip.mp4")
        let annotation = Annotation(comment: "", target: .recording(video: video, seconds: 9.6, source: "Safari window"), frame: .zero, image: nil, contextImage: nil)
        let report = reportText(for: Feedback(annotations: [annotation]), folder: nil)
        #expect(report.contains("- Recorded: Safari window"))
        #expect(report.contains("- Length: 0:10"))
    }
}
