// A plain white window of small text rows, read from a file: a stand-in for an app that changes
// page with the same layout, such as a feed or the iOS Simulator. Rows keep their views, as
// reused elements do. usage: tilde-ux-fixture <file>
import AppKit

let file = CommandLine.arguments[1]
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let screen = NSScreen.screens[0].frame
let window = NSWindow(
    contentRect: NSRect(x: 300, y: screen.height - 200 - 400, width: 500, height: 400),
    styleMask: [.titled], backing: .buffered, defer: false
)
window.title = "Fixture"
window.level = .floating
window.backgroundColor = .white

/// The window's content, which knows when a press reached it, also the first press while
/// another app is in front.
final class PressedView: NSView {
    private(set) var isPressed = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }
}
let content = PressedView()
window.contentView = content

let wordsA = ["Starlink outages disrupt drone operations", "Users campaign to save the old model", "Developer ditches tool over security", "Notaries in Europe face new rules", "Live news is hosting a broadcast now", "Today in the markets stocks were flat", "A new phone was announced this week", "Scientists find water on a far moon", "Trains are late again across the north", "The final match ends in a tie after all"]
let wordsB = ["Mountain weather turns cold for skiers", "Garden tips for planting in the autumn", "Cooking with fewer pans saves an hour", "Museum opens wing for modern painters", "River levels rise after a week of rain", "Chess champion wins with a bold attack", "Library extends its hours for students", "Bakery on the corner sells out by noon", "Hikers rescued from ridge in thick fog", "Orchestra plays a free concert in town"]

var rows: [NSTextField] = []
for index in 0..<10 {
    let row = NSTextField(labelWithString: wordsA[index])
    row.font = .systemFont(ofSize: 14)
    row.textColor = .black
    row.frame = NSRect(x: 24, y: 340 - index * 34, width: 440, height: 22)
    window.contentView?.addSubview(row)
    rows.append(row)
}
// A red mark down the left of the content, on the pages "marked" and "glide": where the window
// is, in each picture of the screen. A press on the window shows it too.
let mark = NSView(frame: NSRect(x: 0, y: 0, width: 6, height: 400))
mark.wantsLayer = true
mark.layer?.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).cgColor
mark.isHidden = true
window.contentView?.addSubview(mark)
window.orderFrontRegardless()

// "glide": the window moves right at 120 pt a second for 1.5 s, once for each frame of the
// display, as a window dragged by hand does. Its place follows the clock, and the app takes no
// nap in the background, which would slow it. A timer would move it less often: each move waits
// for the display.
let awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Moves its window smoothly")

final class Glide: NSObject {
    private let start = Date()
    private let origin = window.frame.origin
    private var link: CADisplayLink?

    func begin() {
        link = content.displayLink(target: self, selector: #selector(step))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func step(_ link: CADisplayLink) {
        let elapsed = min(Date().timeIntervalSince(start), 1.5)
        window.setFrameOrigin(NSPoint(x: origin.x + (120 * elapsed).rounded(), y: origin.y))
        if elapsed == 1.5 {
            link.invalidate()
        }
    }
}
var glide: Glide?
func startGlide() {
    glide = Glide()
    glide?.begin()
}

var lastToggle = Date.distantPast
var fullScreenExits = 0
let exitObserver = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
    MainActor.assumeIsolated { fullScreenExits += 1 }
}
let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    let page = (try? String(contentsOfFile: file, encoding: .utf8)) ?? "a"
    mark.isHidden = !content.isPressed && !page.hasPrefix("marked") && !page.hasPrefix("glide")
    if page.hasPrefix("glide"), glide == nil {
        startGlide()
    }
    var words = page.hasPrefix("b") ? wordsB : wordsA
    // Nearly the same page: one row far from the top changed.
    if page.hasPrefix("almost") {
        words[9] = "The final match ends in a win after all"
    }
    // "fullscreen": the window goes to full screen, in a Space of its own, as a user's app can,
    // and again after it left. "<file>.state" says whether it is, and how many times it left.
    if page.hasPrefix("fullscreen") {
        let state = "fullscreen=\(window.styleMask.contains(.fullScreen)) exits=\(fullScreenExits)"
        try? state.write(toFile: file + ".state", atomically: true, encoding: .utf8)
    }
    if page.hasPrefix("fullscreen"), !window.styleMask.contains(.fullScreen), Date().timeIntervalSince(lastToggle) > 3 {
        lastToggle = Date()
        window.level = .normal
        window.styleMask.insert(.resizable)
        window.collectionBehavior.insert(.fullScreenPrimary)
        app.activate(ignoringOtherApps: true)
        window.toggleFullScreen(nil)
    }
    // The window moved, by a program or by the user.
    if page.hasPrefix("moved"), window.frame.minX < 400 {
        window.setFrameOrigin(NSPoint(x: window.frame.minX + 200, y: window.frame.minY))
    }
    for (row, text) in zip(rows, words) where row.stringValue != text {
        row.stringValue = text
    }
}
withExtendedLifetime((timer, awake, exitObserver)) {
    app.run()
}
