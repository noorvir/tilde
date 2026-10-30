// A plain window whose whole content is one colour, read from a file: a stand-in for an app
// that changes page, for the UX specs. usage: tilde-ux-fixture <file>
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
window.orderFrontRegardless()
let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    let page = (try? String(contentsOfFile: file, encoding: .utf8)) ?? "red"
    switch page {
    case "green": window.backgroundColor = NSColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 1)
    // Close to red, as a page with a small change is close to how it was.
    case "almost": window.backgroundColor = NSColor(red: 0.9, green: 0.22, blue: 0.1, alpha: 1)
    default: window.backgroundColor = NSColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
    }
}
withExtendedLifetime(timer) {
    app.run()
}
