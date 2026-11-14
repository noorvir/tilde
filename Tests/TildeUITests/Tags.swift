import Foundation
import Testing

extension Tag {
    /// Tests that load a page in WebKit. They are reliable only where the web process and the
    /// window server keep up, which a shared CI runner does not always give: CI skips them, and
    /// `scripts/check.sh` runs them. Each such suite also has `.webKitRuns`.
    @Tag static var webKit: Self
}

extension Trait where Self == ConditionTrait {
    /// Off where `TILDE_SKIP_WEBKIT` is set, as on CI, for the suites tagged `webKit`:
    /// `swift test` cannot skip a tag (Swift 6.0 to 6.4 read `--skip` as a name pattern only).
    static var webKitRuns: Self {
        .enabled(if: ProcessInfo.processInfo.environment["TILDE_SKIP_WEBKIT"] == nil, "Loads a WebKit page; TILDE_SKIP_WEBKIT is set")
    }
}
