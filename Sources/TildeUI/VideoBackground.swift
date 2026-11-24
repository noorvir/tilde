import AppKit

/// What a saved video sits on.
enum VideoBackground: Equatable {
    case gradient(VideoGradient)
    /// An image the user added, in `VideoBackgrounds.folder`.
    case image(URL)

    /// As kept in the defaults: "gradient:<name>" or "image:<file name>".
    var key: String {
        switch self {
        case .gradient(let gradient): "gradient:\(gradient.rawValue)"
        case .image(let url): "image:\(url.lastPathComponent)"
        }
    }

    init?(key: String) {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return nil
        }
        switch parts[0] {
        case "gradient":
            guard let gradient = VideoGradient(rawValue: parts[1]) else {
                return nil
            }
            self = .gradient(gradient)
        case "image":
            let url = VideoBackgrounds.folder.appendingPathComponent(parts[1])
            guard FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            self = .image(url)
        default:
            return nil
        }
    }
}

enum VideoGradient: String, CaseIterable {
    case dusk, ocean, peach, aurora, graphite

    var name: String {
        rawValue.capitalized
    }

    /// From the top-left corner to the bottom-right, as "#RRGGBB".
    var colors: [String] {
        switch self {
        case .dusk: ["#3B5BA9", "#8A5FA8", "#D9897A"]
        case .ocean: ["#0F2027", "#2C5364", "#4CA1AF"]
        case .peach: ["#FFB88C", "#F08A7E", "#DE6262"]
        case .aurora: ["#1FA2FF", "#12D8FA", "#A6FFCB"]
        case .graphite: ["#1C1D21", "#3A3D45", "#5B5F6B"]
        }
    }

    var cgColors: [CGColor] {
        colors.map { hex in
            let value = Int(hex.dropFirst(), radix: 16) ?? 0
            return CGColor(srgbRed: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}

/// The backgrounds to choose from: the gradients and the user's own images. The last one
/// chosen is the next clip's.
@MainActor
final class VideoBackgrounds: ObservableObject {
    nonisolated static let folder: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Tilde/Backgrounds", isDirectory: true)
    }()

    /// The user's images, oldest first.
    @Published private(set) var images: [URL] = []
    private(set) var last: VideoBackground
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        last = defaults.string(forKey: "VideoBackground").flatMap(VideoBackground.init(key:)) ?? .gradient(.dusk)
        images = Self.saved()
    }

    func remember(_ background: VideoBackground) {
        last = background
        defaults.set(background.key, forKey: "VideoBackground")
    }

    /// Asks for images and copies them to the folder; returns the last one added.
    func add() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images to put saved videos on"
        NSApp.activate()
        guard panel.runModal() == .OK else {
            return nil
        }
        var added: URL?
        for image in panel.urls {
            let file = Self.folder.appendingPathComponent("\(UUID().uuidString).\(image.pathExtension)")
            do {
                try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: image, to: file)
                added = file
            } catch {
                continue
            }
        }
        images = Self.saved()
        return added
    }

    func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        images = Self.saved()
        if last == .image(url) {
            remember(.gradient(.dusk))
        }
    }

    private static func saved() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        func created(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        }
        return files.sorted { created($0) < created($1) }
    }
}
