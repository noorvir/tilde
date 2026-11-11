import AppKit

/// The screenshots of a note: the close-up of its target, and the context around it.
enum NoteCaptures {
    /// Starts the screenshots of a new target. `window` is the window the target belongs to.
    /// For an element (`outline` set), both screenshots come from that window alone, so no
    /// other window, Tilde's included, can cover them. `withContext`: the session wants the
    /// context image too.
    @MainActor
    static func start(
        of frame: CGRect, outline: CGRect?, window: ElementPicker.WindowInfo?, browser: BrowserController, withContext: Bool
    ) -> Task<Captures, Never> {
        let closeUpRect = closeUpRect(frame: frame, outline: outline)
        let keeping = Set(browser.windowNumber.map { [CGWindowID($0)] } ?? [])
        let isInBrowserPage = window != nil && window?.number == browser.windowNumber
        let pageFrame = browser.pageFrame?.flipped
        return Task {
            // Tilde's browser draws its page itself, with no Screen Recording; the visible part
            // of the page is the context, like a whole window elsewhere.
            if isInBrowserPage || !ScreenCapture.isAllowed {
                let image = await browser.snapshot(of: closeUpRect, outline: outline)
                var contextImage: Data?
                if isInBrowserPage, withContext, let pageFrame {
                    contextImage = await browser.snapshot(of: pageFrame, outline: frame, maxSide: 1024)
                }
                return Captures(image: image, contextImage: contextImage)
            }

            async let image = closeUpImage(of: closeUpRect, outline: outline, window: window, keeping: keeping)
            async let contextImage = contextImage(of: frame, isRegion: outline == nil, window: window, keeping: keeping, enabled: withContext)
            return await Captures(image: image, contextImage: contextImage)
        }
    }

    /// A drawing in its window (or else on its screen) and the whole screen, with the drawings
    /// on them: `keeping` has the canvases' windows.
    @MainActor
    static func ofDrawing(bounds: CGRect, in windowFrame: CGRect?, keeping: Set<CGWindowID>) async -> Captures {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let screen = NSScreen.screens.first { $0.frame.flipped.contains(center) }?.frame.flipped ?? bounds
        async let image = ScreenCapture.png(of: windowFrame ?? screen, outline: nil, keeping: keeping, maxSide: 1600)
        async let wholeScreen = ScreenCapture.png(of: screen, outline: nil, keeping: keeping, maxSide: 2048)
        return await Captures(image: image, contextImage: wholeScreen)
    }

    /// A wireframe's area of the screen as it is with the wireframe on it, and as it is under
    /// it. `canvas` has the canvases' windows; `page` has the window of Tilde's browser, which
    /// both pictures keep.
    @MainActor
    static func ofWireframe(area: CGRect, canvas: Set<CGWindowID>, page: Set<CGWindowID>) async -> Captures {
        async let over = ScreenCapture.png(of: area, outline: nil, keeping: canvas.union(page), maxSide: 2048)
        async let under = ScreenCapture.png(of: area, outline: nil, keeping: page, maxSide: 2048)
        return await Captures(image: over, contextImage: under)
    }

    /// What the close-up shows: an element (`outline` set) with 4 pt around it so its outline
    /// fits, or a region exactly.
    static func closeUpRect(frame: CGRect, outline: CGRect?) -> CGRect {
        outline.map { $0.insetBy(dx: -4, dy: -4) } ?? frame
    }

    /// Whether at least 80% of a region lies inside a window, so the window is its context.
    static func isMostlyInside(_ region: CGRect, _ window: CGRect) -> Bool {
        let inside = window.intersection(region)
        return !inside.isNull && inside.width * inside.height >= 0.8 * region.width * region.height
    }

    /// The target alone: an element from its own window, or a region from the screen. An
    /// element whose window cannot be captured, such as one that just closed, has no picture:
    /// the screen there may show another window.
    private static func closeUpImage(
        of rect: CGRect, outline: CGRect?, window: ElementPicker.WindowInfo?, keeping: Set<CGWindowID>
    ) async -> Data? {
        if let outline, let window {
            return await ScreenCapture.png(ofWindow: CGWindowID(window.number), area: rect, outline: outline, maxSide: 1200)
        }
        return await ScreenCapture.png(of: rect, outline: outline, keeping: keeping, maxSide: 1200)
    }

    /// The whole window the target belongs to, with the target outlined. For a region: the
    /// window that holds most of it, or else its screen. Nil when `enabled` is false.
    private static func contextImage(
        of frame: CGRect, isRegion: Bool, window: ElementPicker.WindowInfo?, keeping: Set<CGWindowID>, enabled: Bool
    ) async -> Data? {
        guard enabled else {
            return nil
        }

        if let window {
            if !isRegion || isMostlyInside(frame, window.frame) {
                return await ScreenCapture.png(ofWindow: CGWindowID(window.number), area: window.frame, outline: frame, maxSide: 1024)
            }
        }

        let center = CGPoint(x: frame.midX, y: frame.midY).flipped
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.screens.first
        let bounds = screen?.frame.flipped ?? frame
        return await ScreenCapture.png(of: bounds, outline: frame, keeping: keeping, maxSide: 1024)
    }
}
