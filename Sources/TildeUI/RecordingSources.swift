import AppKit
import os
import ScreenCaptureKit

/// What a clip records.
enum RecordingSource: Equatable {
    case screen(CGDirectDisplayID)
    case window(ElementPicker.WindowInfo)
    case phone(Phone)

    /// The same while a window moves or resizes.
    var id: String {
        switch self {
        case .screen(let display): "screen-\(display)"
        case .window(let window): "window-\(window.number)"
        case .phone(let phone): "phone-\(phone.id)"
        }
    }
}

/// The recording source picker under the HUD: the screens and a phone on a cable, and the
/// apps' windows, each with a picture taken when the picker opens.
@MainActor
final class SourcePickerModel: ObservableObject {
    enum Tab: Hashable {
        case screens
        case windows
    }

    struct Tile: Identifiable {
        let source: RecordingSource
        let title: String
        /// The smaller grey line under the title, such as the pixel size.
        let detail: String
        var picture: CGImage?

        var id: String { source.id }
    }

    struct App: Identifiable {
        let pid: pid_t
        let name: String
        let icon: NSImage?
        /// Front to back.
        var windows: [Tile]

        var id: pid_t { pid }
    }

    /// Where the list is: listing the sources, taking their pictures, done, or failed, such as
    /// without the Screen Recording permission.
    enum Phase: Equatable {
        case listing
        case picturing
        case done
        case failed
    }

    @Published private(set) var phase = Phase.listing
    /// The most room the picker has under the HUD's pill on its screen; the HUD sets it.
    @Published var space = CGSize(width: 780, height: 900)
    @Published var tab = Tab.screens
    /// The app whose windows are shown, or nil for the list of apps.
    @Published var openApp: pid_t?
    @Published private(set) var screens: [Tile] = []
    @Published private(set) var apps: [App] = []

    private static let log = Logger(subsystem: "dev.tilde.app", category: "picker")
    private var loading: Task<Void, Never>?
    /// Sources offered in place of the screen's, such as fixtures for pictures and tests; a
    /// load treats them as it treats the screen's.
    var injected: (screens: [Tile], apps: [App], phase: Phase)?

    /// Lists the sources on screen now, then takes their pictures, in place of a load still
    /// running. It lists a phone in both modes; the picker offers it only for recording.
    func load(browserWindow: Int?) {
        loading?.cancel()
        if let injected {
            screens = injected.screens
            apps = injected.apps
            phase = injected.phase
            return
        }
        phase = .listing
        loading = Task {
            await reload(browserWindow: browserWindow)
        }
    }

    /// The picker closed: a load still running writes nothing more.
    func stopLoading() {
        loading?.cancel()
        loading = nil
    }

    private func reload(browserWindow: Int?) async {
        var steps = StepTimer()
        let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        steps.mark("content")
        guard !Task.isCancelled else {
            return
        }
        guard let content else {
            screens = []
            apps = []
            phase = .failed
            return
        }

        let displays = content.displays.map { display in
            Tile(source: .screen(display.displayID), title: Self.name(of: display.displayID), detail: Self.pixelSize(of: display.displayID))
        }
        steps.mark("displays")
        let listed = await Self.list(content.windows, browserWindow: browserWindow)
        steps.mark("phones and apps")
        guard !Task.isCancelled else {
            return
        }
        let mayFilmPhones = listed.mayFilmPhones
        screens = displays + listed.phones
        apps = listed.apps

        // Tilde's browser is a window like any other; its other windows are left out.
        let tilde = content.applications.filter { $0.processID == getpid() }
        let browser = content.windows.filter { Int($0.windowID) == browserWindow }
        let tiles = screens + apps.flatMap(\.windows)
        phase = .picturing
        await withTaskGroup(of: (String, CGImage?).self) { group in
            for tile in tiles {
                switch tile.source {
                case .screen(let id):
                    if let display = content.displays.first(where: { $0.displayID == id }) {
                        let filter = SCContentFilter(display: display, excludingApplications: tilde, exceptingWindows: browser)
                        group.addTask { await (tile.id, Self.picture(of: filter, size: display.frame.size)) }
                    }
                case .window(let info):
                    if let window = content.windows.first(where: { Int($0.windowID) == info.number }) {
                        group.addTask { await (tile.id, Self.picture(of: SCContentFilter(desktopIndependentWindow: window), size: window.frame.size)) }
                    }
                case .phone(let phone):
                    if mayFilmPhones {
                        group.addTask { await (tile.id, PhoneCapture.snapshot(of: phone)) }
                    }
                }
            }
            for await (id, picture) in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                setPicture(picture, for: id)
            }
        }
        steps.mark("pictures")
        if !Task.isCancelled {
            phase = .done
        }
        Self.log.notice("picker loaded: \(steps.summary, privacy: .public)")
    }

    private func setPicture(_ picture: CGImage?, for id: String) {
        if let index = screens.firstIndex(where: { $0.id == id }) {
            screens[index].picture = picture
        }
        for appIndex in apps.indices {
            if let index = apps[appIndex].windows.firstIndex(where: { $0.id == id }) {
                apps[appIndex].windows[index].picture = picture
            }
        }
    }

    /// The phones on a cable and the apps' windows. It runs off the main thread: the first
    /// time, listing phones loads AVFoundation's devices, and each app's icon is read from disk.
    nonisolated private static func list(_ windows: [SCWindow], browserWindow: Int?) async -> (phones: [Tile], mayFilmPhones: Bool, apps: [App]) {
        // A phone's picture needs the Camera permission, which is asked for only when the user
        // chooses the phone to record.
        let mayFilmPhones = PhoneCapture.hasCameraAccess
        let phones = PhoneCapture.phones().map { Tile(source: .phone($0), title: $0.name, detail: mayFilmPhones ? "Cable" : "Needs Camera access") }
        return (phones, mayFilmPhones, apps(of: windows, browserWindow: browserWindow))
    }

    /// Apps with normal or floating windows on screen, front to back; Tilde's only with its
    /// browser.
    nonisolated private static func apps(of windows: [SCWindow], browserWindow: Int?) -> [App] {
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? Int }
        let shown = windows
            .filter { window in
                let isOwn = window.owningApplication?.processID == getpid()
                return (0...Int(CGWindowLevelForKey(.floatingWindow))).contains(window.windowLayer) && window.frame.width >= 100 && window.frame.height >= 60
                    && (!isOwn || Int(window.windowID) == browserWindow)
            }
            .sorted { (order.firstIndex(of: Int($0.windowID)) ?? .max) < (order.firstIndex(of: Int($1.windowID)) ?? .max) }

        var apps: [App] = []
        for window in shown {
            guard let owner = window.owningApplication else {
                continue
            }
            let info = ElementPicker.WindowInfo(
                number: Int(window.windowID), pid: owner.processID, app: owner.applicationName, title: window.title.flatMap { $0.isEmpty ? nil : $0 }, frame: window.frame
            )
            let tile = Tile(source: .window(info), title: info.title ?? owner.applicationName, detail: "\(Int(window.frame.width)) × \(Int(window.frame.height))")
            if let index = apps.firstIndex(where: { $0.pid == owner.processID }) {
                apps[index].windows.append(tile)
            } else {
                let icon = NSRunningApplication(processIdentifier: owner.processID)?.icon
                apps.append(App(pid: owner.processID, name: owner.applicationName, icon: icon, windows: [tile]))
            }
        }
        return apps
    }

    nonisolated private static func picture(of filter: SCContentFilter, size: CGSize) async -> CGImage? {
        guard size.width > 0, size.height > 0 else {
            return nil
        }
        let configuration = SCStreamConfiguration()
        // Twice a tile's width, for Retina screens.
        let scale = min(1, 360 / max(size.width, size.height * 1.6))
        configuration.width = Int(size.width * scale)
        configuration.height = Int(size.height * scale)
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    static func name(of display: CGDirectDisplayID) -> String {
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display }
        // A screen with no name, such as a headless Mac's, is "Display".
        guard let name = screen?.localizedName, !name.isEmpty else {
            return "Display"
        }
        return name
    }

    private static func pixelSize(of display: CGDirectDisplayID) -> String {
        guard let mode = CGDisplayCopyDisplayMode(display) else {
            return ""
        }
        return "\(mode.pixelWidth) × \(mode.pixelHeight)"
    }
}

/// The time of each step of a load, for the log.
private struct StepTimer {
    private var last = ContinuousClock.now
    private(set) var summary = ""

    mutating func mark(_ step: String) {
        let now = ContinuousClock.now
        let ms = (now - last).components.attoseconds / 1_000_000_000_000_000 + (now - last).components.seconds * 1000
        summary += "\(step) \(ms) ms, "
        last = now
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
