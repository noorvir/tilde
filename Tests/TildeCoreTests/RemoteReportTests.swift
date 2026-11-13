import Foundation
import Testing
@testable import TildeCore

struct RemoteReportTests {
    @Test func homeRelativeLinksWorkOnAnyMachine() throws {
        let annotation = Annotation(comment: "c", target: .region, frame: .zero, image: Data([1]), contextImage: Data([2]))
        let folder = URL(fileURLWithPath: "/Users/a/.tilde/inbox/x")
        let link = try #require(homeRelativePath(folder, home: URL(fileURLWithPath: "/Users/a")))
        let text = reportText(for: Feedback(annotations: [annotation]), folder: folder, linkFolder: link)
        #expect(text.contains("Saved to: ~/.tilde/inbox/x"))
        #expect(text.contains("(~/.tilde/inbox/x/annotation-1.png)"))
        #expect(text.contains("(~/.tilde/inbox/x/annotation-1-context.png)"))
        #expect(!text.contains("/Users/a"))
    }

    /// A tool that ends before it has read its input, as ssh does when the connection drops
    /// while a config goes to a machine, gives its result: the write to it ends no process.
    @Test func aToolThatReadsNoInputEndsWithItsResult() throws {
        let input = String(repeating: "x", count: 1 << 20)
        #expect(try RemotePush.run("/usr/bin/true", [], input: input) == "")
        #expect(throws: RemotePush.Failure.self) {
            try RemotePush.run("/usr/bin/false", [], input: input)
        }
    }

    @Test func aFolderOutsideTheHomeHasNoHomeRelativePath() {
        #expect(homeRelativePath(URL(fileURLWithPath: "/tmp/x"), home: URL(fileURLWithPath: "/Users/a")) == nil)
    }
}
