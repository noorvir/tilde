import AppKit
import AVFoundation
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

/// What recording mode can record: the screens and phones on a cable, for the source menu,
/// and the apps' windows, for the window grid, each window with a picture taken when the grid
/// opens.
@MainActor
final class SourcePickerModel: ObservableObject {
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

    /// Where the window grid is: listing the windows, taking their pictures, done, or failed,
    /// such as without the Screen Recording permission.
    enum Phase: Equatable {
        case listing
        case picturing
        case done
        case failed
    }

    @Published private(set) var phase = Phase.listing
    /// The most room the window grid has under the HUD's pill on its screen; the HUD sets it.
    @Published var space = CGSize(width: 780, height: 900)
    /// The app whose windows are shown, or nil for the list of apps.
    @Published var openApp: pid_t?
    /// The source menu's screens, then phones; their tiles have no picture.
    @Published private(set) var screens: [Tile] = []
    @Published private(set) var apps: [App] = []

    private var loading: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    /// Sources offered in place of the Mac's, such as fixtures for pictures and tests; a
    /// listing treats them as it treats the Mac's.
    var injected: (screens: [Tile], apps: [App], phase: Phase)?

    /// Lists the screens and phones now, and again whenever a screen or a phone comes or goes.
    func listScreens() {
        if let injected {
            screens = injected.screens
            return
        }
        PhoneCapture.allowPhones()
        let displays = NSScreen.screens.compactMap(\.displayID).map { display in
            Tile(source: .screen(display), title: Self.name(of: display), detail: "")
        }
        let detail = PhoneCapture.hasCameraAccess ? "Cable" : "Needs Camera access"
        let phones = PhoneCapture.phones().map { Tile(source: .phone($0), title: $0.name, detail: detail) }
        screens = displays + phones

        guard observers.isEmpty else {
            return
        }
        let changes: [Notification.Name] = [NSApplication.didChangeScreenParametersNotification, AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification]
        observers = changes.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.listScreens()
                }
            }
        }
    }

    /// Lists the windows on screen now, then takes their pictures, in place of a load still
    /// running.
    func load(browserWindow: Int?) {
        loading?.cancel()
        if let injected {
            apps = injected.apps
            phase = injected.phase
            return
        }
        phase = .listing
        loading = Task {
            await reload(browserWindow: browserWindow)
        }
    }

    /// The window grid closed: a load still running writes nothing more.
    func stopLoading() {
        loading?.cancel()
        loading = nil
    }

    private func reload(browserWindow: Int?) async {
        let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard !Task.isCancelled else {
            return
        }
        guard let content else {
            apps = []
            phase = .failed
            return
        }

        // Tilde's browser is a window like any other; its other windows are left out.
        apps = Self.apps(of: content.windows, browserWindow: browserWindow)
        let tiles = apps.flatMap(\.windows)
        phase = .picturing
        await withTaskGroup(of: (String, CGImage?).self) { group in
            for tile in tiles {
                guard case .window(let info) = tile.source, let window = content.windows.first(where: { Int($0.windowID) == info.number }) else {
                    continue
                }
                group.addTask { await (tile.id, Self.picture(of: SCContentFilter(desktopIndependentWindow: window), size: window.frame.size)) }
            }
            for await (id, picture) in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                setPicture(picture, for: id)
            }
        }
        if !Task.isCancelled {
            phase = .done
        }
    }

    private func setPicture(_ picture: CGImage?, for id: String) {
        for appIndex in apps.indices {
            if let index = apps[appIndex].windows.firstIndex(where: { $0.id == id }) {
                apps[appIndex].windows[index].picture = picture
            }
        }
    }

    /// Apps with normal or floating windows on screen, front to back; Tilde's only with its
    /// browser.
    private static func apps(of windows: [SCWindow], browserWindow: Int?) -> [App] {
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
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
