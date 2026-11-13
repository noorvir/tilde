@testable import TildeUI
import AppKit
import Testing
import WebKit

/// Finding annotated elements again in a real web view: by selector, then by text when the
/// selector no longer matches, and never on another page.
@MainActor
@Suite(.serialized)
struct AnchorTests {
    let browser = BrowserController()
    let id = UUID()

    @Test func findsTheElementBySelectorThenByText() async throws {
        let html = """
            <html><body style="margin:0">
            <div style="height:120px"></div>
            <p id="target" style="margin:0;height:20px">Avatar and name</p>
            </body></html>
            """
        browser.webView.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        browser.webView.loadHTMLString(html, baseURL: URL(string: "https://example.test/a")!)
        try await until { !self.browser.webView.isLoading && self.browser.pageURL == "https://example.test/a" }

        browser.anchors = [id: PageAnchor(url: "https://example.test/a", selector: "#target", text: "Avatar and name", documentRect: .zero)]
        try await until { self.browser.anchorRects[self.id] != nil }
        #expect(browser.anchorRects[id]?.minY == 120)

        // The selector breaks; the text still finds the element.
        _ = try await browser.webView.evaluateJavaScript("document.getElementById('target').removeAttribute('id'); true")
        browser.anchors = [id: PageAnchor(url: "https://example.test/a", selector: "#target", text: "Avatar and name", documentRect: .zero)]
        browser.resolveAnchors()
        try await Task.sleep(for: .milliseconds(300))
        #expect(browser.anchorRects[id]?.minY == 120)

        // An anchor on another page is not looked for here.
        browser.anchors = [id: PageAnchor(url: "https://example.test/b", selector: "p", text: nil, documentRect: .zero)]
        try await until { self.browser.anchorRects.isEmpty }
    }
}
