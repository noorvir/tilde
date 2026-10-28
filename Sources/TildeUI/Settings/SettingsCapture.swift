import AppKit
import OSLog
import ScreenCaptureKit

/// Writes PNGs of the live Settings window, every page in light and dark, so a change can be
/// checked on the real window. Run `open -n /Applications/Tilde.app --args -captureSettings <folder>`.
@MainActor
enum SettingsCapture {
    private static let log = Logger(subsystem: "dev.tilde.app", category: "settings-capture")

    static func run(_ settings: SettingsWindow, model: SettingsModel, to folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let states: [(name: String, page: SettingsWindow.Page, expanded: Set<String>)] = [
            ("general", .general, []), ("agents", .agents, []), ("agents-open", .agents, ["Claude", "Codex"]), ("shortcuts", .shortcuts, []),
        ]

        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for state in states {
                settings.show(state.page)
                model.expandedAgents = state.expanded
                settings.window?.appearance = NSAppearance(named: appearance)
                try? await Task.sleep(for: .milliseconds(600))
                guard let window = settings.window, let data = await png(of: window) else {
                    log.error("could not capture settings \(state.name, privacy: .public)")
                    continue
                }
                try? data.write(to: folder.appendingPathComponent("live-\(state.name)-\(suffix).png"))
            }
        }
        NSApp.terminate(nil)
    }

    private static func png(of window: NSWindow) async -> Data? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                log.error("settings window \(window.windowNumber) is not in the shareable content")
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = Int(target.frame.width * scale)
            configuration.height = Int(target.frame.height * scale)
            configuration.showsCursor = false
            configuration.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        } catch {
            log.error("capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
