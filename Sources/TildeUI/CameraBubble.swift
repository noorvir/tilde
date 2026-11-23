import AppKit
import AVFoundation
import SwiftUI

/// The camera bubble of recording mode: the user's camera in a round or rounded window that
/// screen clips record, with a bar under it for the camera, the microphone, the shape, the
/// size and the background of a saved video. The camera runs only while the bubble shows. The choices stay across launches.
@MainActor
final class CameraBubble: ObservableObject {
    enum Shape: String {
        case circle, rounded
    }

    enum Menu {
        case camera, microphone, background
    }

    static let sides: [CGFloat] = [140, 200, 280]

    /// The recording bar's camera button: the bubble shows in recording mode while on.
    @Published private(set) var isOn: Bool
    @Published private(set) var cameraID: String?
    @Published private(set) var isMicrophoneOn: Bool
    @Published private(set) var microphoneID: String?
    @Published private(set) var shape: Shape
    @Published private(set) var sizeIndex: Int
    @Published private(set) var openMenu: Menu?
    /// What Save video puts the clip on.
    @Published private(set) var background: VideoBackground
    /// The user's own backgrounds, oldest first.
    @Published private(set) var customBackgrounds: [URL] = []
    /// The camera may not be used: the bubble shows a crossed-out camera.
    @Published private(set) var isDenied = false

    private let defaults: UserDefaults
    private let capture = CameraCapture()
    private var bubblePanel: BubblePanel?
    private var barPanel: BubblePanel?
    private var isShown = false
    private var showsBar = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isOn = defaults.bool(forKey: "CameraOn")
        cameraID = defaults.string(forKey: "CameraID")
        isMicrophoneOn = defaults.object(forKey: "CameraMicrophoneOn") as? Bool ?? true
        microphoneID = defaults.string(forKey: "CameraMicrophoneID")
        shape = defaults.string(forKey: "CameraShape").flatMap(Shape.init(rawValue:)) ?? .circle
        sizeIndex = min(max(defaults.object(forKey: "CameraSize") as? Int ?? 1, 0), Self.sides.count - 1)
        background = defaults.string(forKey: "VideoBackground").flatMap(VideoBackground.init(key:)) ?? .gradient(.dusk)
        customBackgrounds = Self.savedBackgrounds()
    }

    var side: CGFloat {
        Self.sides[sizeIndex]
    }

    /// The bubble's window while it shows, for a clip to keep it.
    var windowNumber: Int? {
        guard isShown, let bubblePanel else {
            return nil
        }
        return bubblePanel.windowNumber
    }

    /// The microphone a clip records, as `AVCaptureDevice.uniqueID`; nil for no sound. Only a
    /// clip with the camera records sound.
    var microphone: String? {
        guard windowNumber != nil, isMicrophoneOn else {
            return nil
        }
        return microphoneID ?? AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external], mediaType: .video, position: .unspecified).devices
    }

    var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    /// The camera in use: the chosen one while it is there, else the system's.
    var currentCameraID: String? {
        let all = cameras
        if let cameraID, all.contains(where: { $0.uniqueID == cameraID }) {
            return cameraID
        }
        return AVCaptureDevice.default(for: .video)?.uniqueID ?? all.first?.uniqueID
    }

    var currentMicrophoneID: String? {
        microphoneID ?? AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    // MARK: - Choices

    func toggle() {
        isOn.toggle()
        defaults.set(isOn, forKey: "CameraOn")
        openMenu = nil
        refresh()
    }

    func toggleMenu(_ menu: Menu) {
        openMenu = openMenu == menu ? nil : menu
        layoutBar()
    }

    func chooseCamera(_ id: String) {
        cameraID = id
        defaults.set(id, forKey: "CameraID")
        openMenu = nil
        capture.use(cameraID: id)
        layoutBar()
    }

    func toggleMicrophone() {
        isMicrophoneOn.toggle()
        defaults.set(isMicrophoneOn, forKey: "CameraMicrophoneOn")
    }

    func chooseMicrophone(_ id: String) {
        microphoneID = id
        isMicrophoneOn = true
        defaults.set(id, forKey: "CameraMicrophoneID")
        defaults.set(true, forKey: "CameraMicrophoneOn")
        openMenu = nil
        layoutBar()
    }

    func chooseBackground(_ background: VideoBackground) {
        self.background = background
        defaults.set(background.key, forKey: "VideoBackground")
        openMenu = nil
        layoutBar()
    }

    /// Asks for images, copies them to the backgrounds folder, and uses the last one.
    func addBackgrounds() {
        openMenu = nil
        layoutBar()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose images to put saved videos on"
        NSApp.activate()
        guard panel.runModal() == .OK else {
            return
        }
        var added: URL?
        for image in panel.urls {
            let file = VideoBackground.folder.appendingPathComponent("\(UUID().uuidString).\(image.pathExtension)")
            do {
                try FileManager.default.createDirectory(at: VideoBackground.folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: image, to: file)
                added = file
            } catch {
                continue
            }
        }
        customBackgrounds = Self.savedBackgrounds()
        if let added {
            chooseBackground(.image(added))
        }
    }

    func removeBackground(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        customBackgrounds = Self.savedBackgrounds()
        if background == .image(url) {
            chooseBackground(.gradient(.dusk))
        }
    }

    private static func savedBackgrounds() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: VideoBackground.folder, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
        )) ?? []
        func created(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        }
        return files.sorted { created($0) < created($1) }
    }

    func toggleShape() {
        shape = shape == .circle ? .rounded : .circle
        defaults.set(shape.rawValue, forKey: "CameraShape")
    }

    /// Small, medium, large, then small again; the bubble keeps its bottom-left corner.
    func nextSize() {
        sizeIndex = (sizeIndex + 1) % Self.sides.count
        defaults.set(sizeIndex, forKey: "CameraSize")
        if let bubblePanel {
            bubblePanel.setFrame(NSRect(origin: bubblePanel.frame.origin, size: NSSize(width: side, height: side)), display: true)
        }
        layoutBar()
    }

    // MARK: - On screen

    /// Shows the bubble while `isRecordMode` and the camera is on; its bar while `showsBar`,
    /// which is off while a clip records.
    func update(isRecordMode: Bool, showsBar: Bool) {
        let shows = isRecordMode && isOn
        guard shows != isShown || showsBar != self.showsBar else {
            return
        }
        isShown = shows
        self.showsBar = showsBar
        if !showsBar {
            openMenu = nil
        }
        refresh()
    }

    private func refresh() {
        guard isShown, isOn else {
            capture.stop()
            barPanel?.orderOut(nil)
            bubblePanel?.orderOut(nil)
            return
        }
        let bubble = bubblePanel ?? makeBubblePanel()
        bubble.orderFrontRegardless()
        startCamera()
        let bar = barPanel ?? makeBarPanel()
        if showsBar {
            // Ordering out detaches a child window.
            if bar.parent == nil {
                bubble.addChildWindow(bar, ordered: .above)
            }
            layoutBar()
            bar.orderFrontRegardless()
        } else {
            bar.orderOut(nil)
        }
    }

    private func startCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isDenied = false
            capture.start(cameraID: currentCameraID)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    isDenied = !granted
                    if granted, isShown {
                        capture.start(cameraID: currentCameraID)
                    }
                }
            }
        default:
            isDenied = true
        }
    }

    private func makeBubblePanel() -> BubblePanel {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        // Bottom-left, with room for its bar under it.
        let origin = NSPoint(x: screen.minX + 24, y: screen.minY + 24 + HUDAccessory.size.height + 8)
        let panel = BubblePanel(frame: NSRect(origin: origin, size: NSSize(width: side, height: side)), movesByDrag: true)
        panel.contentView = NSHostingView(rootView: CameraBubbleView(bubble: self, session: capture.session))
        bubblePanel = panel
        return panel
    }

    private func makeBarPanel() -> BubblePanel {
        let panel = BubblePanel(frame: .zero, movesByDrag: false)
        panel.contentView = FirstMouseHostingView(rootView: CameraBubbleBar(bubble: self))
        barPanel = panel
        return panel
    }

    /// The bar under the bubble, left-aligned with it; an open menu grows it upward, over the
    /// bubble.
    private func layoutBar() {
        guard let barPanel, let bubblePanel, let content = barPanel.contentView else {
            return
        }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let barTop = bubblePanel.frame.minY - 8
        let origin = NSPoint(x: bubblePanel.frame.minX, y: barTop - HUDAccessory.size.height)
        barPanel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// A borderless panel that floats over other apps without taking the keyboard.
private final class BubblePanel: NSPanel {
    private let movesByDrag: Bool

    init(frame: NSRect, movesByDrag: Bool) {
        self.movesByDrag = movesByDrag
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if movesByDrag, event.type == .leftMouseDown {
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }
}

/// Runs the capture session that the bubble's picture shows, off the main thread.
private final class CameraCapture: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "dev.tilde.camera")

    func start(cameraID: String?) {
        use(cameraID: cameraID)
        queue.async { [session] in
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    func use(cameraID: String?) {
        queue.async { [session] in
            let device = cameraID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video)
            let current = session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device.uniqueID }
            guard let device, current != [device.uniqueID], let input = try? AVCaptureDeviceInput(device: device) else {
                return
            }
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            if session.canAddInput(input) {
                session.addInput(input)
            }
            session.commitConfiguration()
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }
}

// MARK: - Views

private struct CameraBubbleView: View {
    @ObservedObject var bubble: CameraBubble
    let session: AVCaptureSession

    var body: some View {
        let clip = bubble.shape == .circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: bubble.side * 0.2))
        ZStack {
            Color.tildeInk
            if bubble.isDenied {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: bubble.side * 0.2))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                CameraPreview(session: session)
            }
        }
        .clipShape(clip)
        .overlay(clip.stroke(Color.white.opacity(0.9), lineWidth: 3))
        .frame(width: bubble.side, height: bubble.side)
        .accessibilityLabel("Camera")
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        // A mirror, as people expect to see themselves.
        layer.connection?.automaticallyAdjustsVideoMirroring = false
        layer.connection?.isVideoMirrored = true
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// Under the bubble: camera and microphone menus, shape, size, and camera off.
private struct CameraBubbleBar: View {
    @ObservedObject var bubble: CameraBubble

    var body: some View {
        let size = HUDAccessory.size
        VStack(alignment: .leading, spacing: 8) {
            switch bubble.openMenu {
            case .camera: cameraMenu
            case .microphone: microphoneMenu
            case .background: backgroundMenu
            case nil: EmptyView()
            }
            HStack(spacing: size.scaled(2)) {
                deviceButton("video.fill", menu: .camera, help: "Camera")
                deviceButton(bubble.isMicrophoneOn ? "mic.fill" : "mic.slash.fill", menu: .microphone, help: "Microphone")
                deviceButton("photo", menu: .background, help: "Background of saved videos")
                HUDBarDivider()
                HUDButton(image: Image(systemName: bubble.shape == .circle ? "circle" : "app"), help: "Shape") {
                    bubble.toggleShape()
                }
                HUDButton(image: Image(systemName: "arrow.up.left.and.arrow.down.right"), help: "Size") {
                    bubble.nextSize()
                }
                HUDBarDivider()
                HUDButton(image: Image(systemName: "xmark"), help: "Turn camera off") {
                    bubble.toggle()
                }
            }
            .pillInsets(size)
            .pill()
        }
        .fixedSize()
        .environment(\.colorScheme, .dark)
    }

    private func deviceButton(_ symbol: String, menu: CameraBubble.Menu, help: String) -> some View {
        Button {
            bubble.toggleMenu(menu)
        } label: {
            HUDButtonLabel(image: Image(systemName: symbol), opensBelow: true)
                .modifier(HUDButtonChrome(isActive: bubble.openMenu == menu, padding: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
    }

    private var cameraMenu: some View {
        MenuCard {
            ForEach(bubble.cameras, id: \.uniqueID) { camera in
                MenuRow(symbol: "video", title: camera.localizedName, isOn: camera.uniqueID == bubble.currentCameraID) {
                    bubble.chooseCamera(camera.uniqueID)
                }
            }
        }
    }

    private var microphoneMenu: some View {
        MenuCard {
            MenuRow(symbol: "mic", title: "Record microphone", isOn: bubble.isMicrophoneOn) {
                bubble.toggleMicrophone()
            }
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1).padding(.vertical, 3).padding(.horizontal, 6)
            ForEach(bubble.microphones, id: \.uniqueID) { microphone in
                MenuRow(symbol: "waveform", title: microphone.localizedName, isOn: microphone.uniqueID == bubble.currentMicrophoneID) {
                    bubble.chooseMicrophone(microphone.uniqueID)
                }
            }
        }
    }
}

extension CameraBubbleBar {
    fileprivate var backgroundMenu: some View {
        MenuCard {
            MenuRow(symbol: "rectangle.dashed", title: "No background", isOn: bubble.background == .none) {
                bubble.chooseBackground(.none)
            }
            ForEach(VideoGradient.allCases, id: \.self) { gradient in
                BackgroundRow(title: gradient.name, swatch: AnyView(gradientSwatch(gradient)), isOn: bubble.background == .gradient(gradient)) {
                    bubble.chooseBackground(.gradient(gradient))
                }
            }
            ForEach(Array(bubble.customBackgrounds.enumerated()), id: \.element) { index, url in
                BackgroundRow(title: "Image \(index + 1)", swatch: AnyView(imageSwatch(url)), isOn: bubble.background == .image(url)) {
                    bubble.chooseBackground(.image(url))
                }
                .contextMenu {
                    Button("Remove") { bubble.removeBackground(url) }
                }
            }
            MenuRow(symbol: "plus", title: "Add image…") {
                bubble.addBackgrounds()
            }
        }
    }

    private func gradientSwatch(_ gradient: VideoGradient) -> some View {
        LinearGradient(colors: gradient.cgColors.map { Color(cgColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private func imageSwatch(_ url: URL) -> some View {
        Group {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.gray
            }
        }
    }
}

/// A row with a small picture of a background in place of the icon.
private struct BackgroundRow: View {
    let title: String
    let swatch: AnyView
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        let size = HUDAccessory.size
        Button(action: action) {
            HStack(spacing: size.scaled(6)) {
                swatch
                    .frame(width: 22, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.25)))
                Text(title)
                    .font(.system(size: size.font(12.5), weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark")
                    .font(.system(size: size.font(10.5), weight: .semibold))
                    .opacity(isOn ? 1 : 0)
            }
            .modifier(HUDButtonChrome(width: 260, isOn: isOn, padding: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A HUD card of rows, as the source dropdown.
struct MenuCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        let size = HUDAccessory.size
        VStack(spacing: size.scaled(2)) {
            content()
        }
        .frame(width: 260)
        .padding(size.scaled(4))
        .hudCard(cornerRadius: size.scaled(12))
        .environment(\.pillSize, size)
    }
}

/// A row of a HUD card: grey with a check mark while it is the current choice.
struct MenuRow: View {
    let symbol: String
    let title: String
    var isOn = false
    let action: () -> Void

    var body: some View {
        let size = HUDAccessory.size
        Button(action: action) {
            HStack(spacing: size.scaled(4)) {
                HUDButtonLabel(image: Image(systemName: symbol), title: title, fillsWidth: true)
                Image(systemName: "checkmark")
                    .font(.system(size: size.font(10.5), weight: .semibold))
                    .opacity(isOn ? 1 : 0)
            }
            .modifier(HUDButtonChrome(width: 260, isOn: isOn, padding: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
