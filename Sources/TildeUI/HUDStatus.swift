import AppKit
import SwiftUI

/// What the pill's title and subtitle say in each mode.
extension HUDView {
    /// The title and the leading button of one mode.
    struct Status: Equatable {
        var title: String
        /// The clip's length after the title: running since a date, or stopped.
        var clock: Clock?
        var symbol: String
        var tint: Color?
        var help: String
        /// The keys that do the same, in the tooltip; the view adds the in-app key.
        var keys: [String] = []
        /// Starting, saving or sending: the leading button and the record toggle wait.
        var isBusy = false

        enum Clock: Equatable {
            case running(since: Date, before: TimeInterval)
            case stopped(TimeInterval)
        }
    }

    static func status(of controller: AnnotationController) -> Status {
        let shortcut = controller.shortcuts.shortcut(for: .startAnnotation) ?? controller.shortcuts.shortcut(for: .togglePause)
        let clock = controller.clips.clock
        switch controller.mode {
        case .sending(_, let returnTo):
            var status = status(of: returnTo, shortcut: shortcut, clock: clock)
            status.title = "Sending"
            status.clock = nil
            status.isBusy = true
            return status
        case .open(let open):
            return status(of: open, shortcut: shortcut, clock: clock)
        case .idle, .sent:
            return status(of: SessionFlow.Open(), shortcut: nil, clock: clock)
        }
    }

    /// "Pause" with Esc, and when paused "Annotate" with the start shortcut, such as ⌃⌃; in
    /// recording mode the record button, red to start or resume a clip and pause while it records.
    static func status(of open: SessionFlow.Open, shortcut: Shortcut?, clock: (since: Date, before: TimeInterval)) -> Status {
        switch open.activity {
        case .picking:
            var back = open
            back.activity = .recording(.ready)
            var status = status(of: back, shortcut: shortcut, clock: clock)
            status.title = "Choose a window"
            return status
        case .annotating:
            if open.pauses.isEmpty {
                return Status(title: "Annotating", symbol: "pause.fill", help: "Pause", keys: ["Esc"])
            }
            return Status(title: "Paused", symbol: "play.fill", help: "Annotate", keys: shortcut.map { [$0.chip] } ?? [])
        case .recording(let clip):
            switch clip {
            case .ready:
                return Status(title: "Ready to record", symbol: "circle.fill", tint: .red, help: "Record")
            case .starting:
                return Status(title: "Starting", symbol: "circle.fill", tint: .red, help: "Record", isBusy: true)
            case .recording:
                return Status(title: "Recording", clock: .running(since: clock.since, before: clock.before), symbol: "pause.fill", help: "Pause")
            case .paused:
                return Status(title: "Paused", clock: .stopped(clock.before), symbol: "circle.fill", tint: .red, help: "Resume")
            case .finishing:
                return Status(title: "Saving", symbol: "circle.fill", tint: .red, help: "Record", isBusy: true)
            }
        }
    }

    /// Every title the HUD shows, with the widest clock, for the width of the title column.
    static let titles: [String] = {
        let modes: [SessionFlow.Open] = [
            SessionFlow.Open(), SessionFlow.Open(pauses: [.user]), SessionFlow.Open(activity: .picking(isPickerOpen: false)),
        ] + [SessionFlow.Clip.ready, .starting(operation: 0), .recording, .paused, .finishing(operation: 0, thenSend: false)].map {
            SessionFlow.Open(activity: .recording($0))
        }
        let statuses = modes.map { status(of: $0, shortcut: nil, clock: (Date(), 0)) }
        return statuses.map { $0.clock == nil ? $0.title : "\($0.title) 00:00" } + ["Sending"]
    }()

    enum SubtitleState: Equatable {
        case annotating
        case choosingWindow
        /// The picker is open, where Esc goes back one level.
        case inPicker
        case paused(shortcut: Shortcut?)
        /// Another app is in front of the window being annotated.
        case waitingForWindow
        /// The hold key is down; its symbol.
        case holding(String)
        case notice(String)
        /// Recording mode: the name of what Record records.
        case source(String)
    }

    /// The subtitle: an optional word, an optional app icon, a name or text, and a remote
    /// agent's machine.
    struct SubtitlePart: Equatable {
        var prefix: String?
        var icon: NSImage?
        var text: String?
        /// A remote agent's machine, as its icon after the name; its host is in the tooltip.
        var machine: Machine?
    }

    /// A remote machine and its status, drawn as on the Agents page.
    struct Machine: Equatable {
        let host: String
        let dot: NodeSetup.Dot
    }

    /// The width the title column has in the fixed pill. Every agent's name fits it in full.
    static let subtitleWidth: CGFloat = 140
    static let clipboardIcon = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard")
    static let subtitleFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)

    /// What the subtitle says: a notice or what to do now, else where the report goes, such as
    /// "for Codex" and the remote machine's icon.
    static func subtitlePart(client: String?, clientIcon: NSImage?, machine: Machine?, state: SubtitleState) -> SubtitlePart {
        switch state {
        case .notice(let text):
            return SubtitlePart(text: text)
        case .holding(let key):
            return SubtitlePart(text: "Release \(key) to annotate")
        case .waitingForWindow:
            return SubtitlePart(text: "Click the window")
        case .choosingWindow:
            return SubtitlePart(text: "Esc cancels")
        case .inPicker:
            return SubtitlePart(text: "Esc goes back")
        case .source(let name):
            return SubtitlePart(text: name)
        // Paused, it still says where the report goes; the button's tooltip has the shortcut.
        case .annotating, .paused:
            break
        }

        guard let client else {
            return SubtitlePart()
        }
        return SubtitlePart(prefix: "for", icon: clientIcon, text: client, machine: machine)
    }

    /// The width of a subtitle in the HUD's subtitle font.
    static func width(of part: SubtitlePart) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: subtitleFont]
        func width(_ words: [String]) -> CGFloat {
            words.map { ($0 as NSString).size(withAttributes: attributes).width }.reduce(0, +)
        }

        let words = [part.prefix, part.text].compactMap { $0 }
        let icon: CGFloat = part.icon == nil ? 0 : 14
        let gaps = CGFloat(max(words.count + (part.icon == nil ? 0 : 1) - 1, 0)) * 3
        // The machine's icon, after a 3 pt gap.
        let machine: CGFloat = part.machine == nil ? 0 : 3 + 14
        return width(words) + icon + gaps + machine
    }
}
