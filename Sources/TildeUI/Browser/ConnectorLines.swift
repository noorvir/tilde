import SwiftUI

/// Where the page, the notes list and each note card are, for the lines between notes and
/// their elements.
struct NoteGeometry: PreferenceKey {
    struct Value {
        var page: Anchor<CGRect>?
        var panel: Anchor<CGRect>?
        var cards: [UUID: Anchor<CGRect>] = [:]
    }

    static let defaultValue = Value()

    static func reduce(value: inout Value, nextValue: () -> Value) {
        let next = nextValue()
        value.page = value.page ?? next.page
        value.panel = value.panel ?? next.panel
        value.cards.merge(next.cards) { current, _ in current }
    }
}

/// A thin Tilde-blue curve from each visible note on the open page to its element, with an
/// outline on the element. Notes or elements scrolled out of view get no line.
struct ConnectorLines: View {
    @ObservedObject var browser: BrowserController
    let geometry: NoteGeometry.Value
    let proxy: GeometryProxy

    var body: some View {
        // The web view is an AppKit view above SwiftUI's own drawing, so the lines are drawn
        // in a view of their own on top of it.
        AboveAppKit {
            LinesCanvas(lines: lines)
                .ignoresSafeArea()
        }
    }

    struct Line: Equatable {
        let card: CGRect
        let element: CGRect
        let number: Int
        let isSelected: Bool
        let isFlashing: Bool
    }

    private var lines: [Line] {
        guard let pageAnchor = geometry.page, let panelAnchor = geometry.panel, browser.showsNotes else {
            return []
        }
        let page = proxy[pageAnchor]
        let panel = proxy[panelAnchor]

        return geometry.cards.compactMap { id, cardAnchor in
            guard let rect = browser.anchorRects[id] else {
                return nil
            }
            let card = proxy[cardAnchor]
            let element = rect.offsetBy(dx: page.minX, dy: page.minY).intersection(page)
            guard !element.isNull, element.height > 2, card.midY > panel.minY, card.midY < panel.maxY else {
                return nil
            }
            let number = (browser.controller?.drafts.firstIndex { $0.id == id } ?? 0) + 1
            return Line(card: card, element: element, number: number, isSelected: browser.selectedNote == id, isFlashing: browser.flashedNote == id)
        }
    }
}

private struct LinesCanvas: View {
    let lines: [ConnectorLines.Line]

    var body: some View {
        Canvas { context, _ in
            let blue = Color.tildeBlue
            for line in lines {
                // Light by default, a little stronger for the selected note.
                let strength = line.isSelected ? 0.85 : 0.5
                let outline = Path(roundedRect: line.element.insetBy(dx: -2, dy: -2), cornerRadius: 4)
                context.fill(outline, with: .color(blue.opacity(line.isFlashing ? 0.25 : line.isSelected ? 0.08 : 0.03)))
                context.stroke(outline, with: .color(blue.opacity(strength)), lineWidth: 1)

                let start = CGPoint(x: line.card.minX, y: line.card.midY)
                let end = CGPoint(x: line.element.maxX + 2, y: line.element.midY)
                let bend = max((start.x - end.x) / 2, 24)
                var path = Path()
                path.move(to: start)
                path.addCurve(to: end, control1: CGPoint(x: start.x - bend, y: start.y), control2: CGPoint(x: end.x + bend, y: end.y))
                context.stroke(path, with: .color(blue.opacity(strength)), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 3]))
                context.fill(Path(ellipseIn: CGRect(x: end.x - 2, y: end.y - 2, width: 4, height: 4)), with: .color(blue.opacity(strength)))

                // The note's number on the element's top right corner, as the overlay draws it.
                let badge = CGRect(x: line.element.maxX - 7, y: line.element.minY - 9, width: 18, height: 18)
                context.fill(Path(ellipseIn: badge), with: .color(blue))
                context.stroke(Path(ellipseIn: badge), with: .color(.white), lineWidth: 1.5)
                context.draw(
                    Text("\(line.number)").font(.system(size: 10.5, weight: .bold).monospacedDigit()).foregroundColor(.white),
                    at: CGPoint(x: badge.midX, y: badge.midY)
                )
            }
        }
    }
}

/// SwiftUI content in an AppKit view of its own, so it draws above sibling AppKit views such
/// as the web view. It never takes clicks.
struct AboveAppKit<Content: View>: NSViewRepresentable {
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> PassThroughHostingView<Content> {
        let view = PassThroughHostingView(rootView: content)
        view.sizingOptions = []
        // The lines use the window's coordinates, so the title bar must not push them down.
        view.safeAreaRegions = []
        return view
    }

    func updateNSView(_ view: PassThroughHostingView<Content>, context: Context) {
        view.rootView = content
    }
}

final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
