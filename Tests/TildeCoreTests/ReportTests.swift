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

    /// Every report, at Send or made again from History, puts the notes of one web page
    /// together, pages in the order they were first noted; its numbers and file names follow.
    @Test func aReportPutsEachPagesNotesTogether() throws {
        func note(_ comment: String, on page: String?) throws -> Annotation {
            var target = Target.region
            if let page {
                let json = #"{"url":"\#(page)","title":"","tag":"a","selector":"a","text":"","html":"","components":[],"source":null,"styles":""}"#
                target = .element(.web(try JSONDecoder().decode(WebElement.self, from: Data(json.utf8))))
            }
            return Annotation(comment: comment, target: target, frame: .zero, image: nil, contextImage: nil)
        }
        let notes = [try note("A1", on: "http://a/"), try note("R", on: nil), try note("B1", on: "http://b/"), try note("A2", on: "http://a/")]

        #expect(Feedback(annotations: notes).annotations.map(\.comment) == ["A1", "A2", "B1", "R"])
    }
}
