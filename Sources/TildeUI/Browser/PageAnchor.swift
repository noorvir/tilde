import Foundation

/// Where an annotation sits on a web page, so the browser can find it again after the page
/// scrolls, changes or is visited again.
struct PageAnchor: Equatable, Sendable, Codable {
    /// The page, without its fragment.
    let url: String
    /// The element's CSS selector; nil for a dragged region.
    let selector: String?
    /// The start of the element's text, to find it when the selector no longer matches.
    let text: String?
    /// The element or region in document coordinates (CSS pixels from the top of the page).
    let documentRect: CGRect

    var isRegion: Bool {
        selector == nil
    }

    /// The URL without its fragment, so in-page links stay on the same page.
    static func pageURL(_ url: URL?) -> String? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.fragment = nil
        return components.string
    }

    /// The path the panel shows for a page, such as "/docs/setup".
    static func shortName(of url: String) -> String {
        guard let components = URLComponents(string: url) else {
            return url
        }
        let path = components.path.isEmpty ? "/" : components.path
        return components.query.map { "\(path)?\($0)" } ?? path
    }
}
