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
window.orderFrontRegardless()
let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    let page = (try? String(contentsOfFile: file, encoding: .utf8)) ?? "a"
    var words = page.hasPrefix("b") ? wordsB : wordsA
    // Nearly the same page: one row far from the top changed.
    if page.hasPrefix("almost") {
        words[9] = "The final match ends in a win after all"
    }
    // The window moved, by a program or by the user.
    if page.hasPrefix("moved"), window.frame.minX < 400 {
        window.setFrameOrigin(NSPoint(x: window.frame.minX + 200, y: window.frame.minY))
    }
    for (row, text) in zip(rows, words) where row.stringValue != text {
        row.stringValue = text
    }
}
withExtendedLifetime(timer) {
    app.run()
}
