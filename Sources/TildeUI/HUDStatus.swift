import AppKit
import SwiftUI

/// What the pill's title and subtitle say in each mode.
extension HUDView {
    /// The title of one mode and the dot before it.
    struct Status: Equatable {
        var title: String
        /// The clip's length after the title: running since a date, or stopped.
        var clock: Clock?
        /// Blue while annotating, red while a clip records, grey in every other state.
        var dot: Color
        /// Starting, saving or sending: the buttons of the modes wait.
        var isBusy = false

        enum Clock: Equatable {
            case running(since: Date, before: TimeInterval)
            case stopped(TimeInterval)
        }
    }

    static func status(of controller: AnnotationController) -> Status {
        let clock = controller.clips.clock
        switch controller.mode {
        case .sending:
            return Status(title: "Sending", dot: idleDot, isBusy: true)
        case .open(let open):
            return status(of: open, clock: clock)
        case .idle, .sent:
            return status(of: SessionFlow.Open(), clock: clock)
        }
    }

    static func status(of open: SessionFlow.Open, clock: (since: Date, before: TimeInterval)) -> Status {
        switch open.activity {
        case .picking:
            return Status(title: "Choose a window", dot: idleDot)
        case .annotating:
            if open.pauses.isEmpty {
                return Status(title: "Annotating", dot: .tildeBlue)
            }
            return Status(title: "Paused", dot: idleDot)
        case .recording(let clip):
            switch clip {
            case .ready:
                return Status(title: "Ready to record", dot: idleDot)
            case .starting:
                return Status(title: "Starting", dot: idleDot, isBusy: true)
            case .recording:
                return Status(title: "Recording", clock: .running(since: clock.since, before: clock.before), dot: .red)
            case .paused:
                return Status(title: "Paused", clock: .stopped(clock.before), dot: idleDot)
            case .finishing:
                return Status(title: "Saving", dot: idleDot, isBusy: true)
            }
        }
    }

    private static let idleDot = Color.white.opacity(0.35)

    /// Every title the HUD shows, with the widest clock, for the width of the title column.
    static let titles: [String] = {
        let modes: [SessionFlow.Open] = [
            SessionFlow.Open(), SessionFlow.Open(pauses: [.user]), SessionFlow.Open(activity: .picking(isPickerOpen: false)),
        ] + [SessionFlow.Clip.ready, .starting(operation: 0), .recording, .paused, .finishing(operation: 0, then: .stay)].map {
            SessionFlow.Open(activity: .recording($0))
        }
        let statuses = modes.map { status(of: $0, clock: (Date(), 0)) }
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

    /// A remote machine and its status, drawn as on the Home page of Settings.
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
        // Paused, it still says where the report goes.
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
